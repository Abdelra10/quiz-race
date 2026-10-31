create extension if not exists pgcrypto;

create table if not exists public.quiz_questions (
  id bigserial primary key,
  category text not null,
  prompt text not null,
  options jsonb not null,
  correct_index integer not null check (correct_index between 0 and 3)
);

create table if not exists public.quiz_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z]{4}$'),
  host_player_id uuid,
  status text not null default 'lobby' check (status in ('lobby','question','reveal','finished')),
  round_number integer not null default 0,
  question_index integer not null default 0,
  question_started_at timestamptz,
  question_deadline timestamptz,
  reveal_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.quiz_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  display_name text not null,
  score integer not null default 0,
  is_host boolean not null default false,
  waiting_next_round boolean not null default false,
  joined_at timestamptz not null default now()
);

create table if not exists public.quiz_player_sessions (
  player_id uuid primary key references public.quiz_players(id) on delete cascade,
  token_hash text not null
);

create table if not exists public.quiz_room_questions (
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  round_number integer not null,
  question_order integer not null,
  question_id bigint not null references public.quiz_questions(id),
  primary key(room_id, round_number, question_order)
);

create table if not exists public.quiz_used_questions (
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  question_id bigint not null references public.quiz_questions(id),
  primary key(room_id, question_id)
);

create table if not exists public.quiz_answers (
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  round_number integer not null,
  question_order integer not null,
  player_id uuid not null references public.quiz_players(id) on delete cascade,
  option_index integer not null check (option_index between 0 and 3),
  is_correct boolean not null,
  points integer not null default 0,
  answered_at timestamptz not null default now(),
  primary key(room_id, round_number, question_order, player_id)
);

alter table public.quiz_rooms enable row level security;
alter table public.quiz_players enable row level security;
alter table public.quiz_player_sessions enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_room_questions enable row level security;
alter table public.quiz_used_questions enable row level security;
alter table public.quiz_answers enable row level security;

create or replace function public.game_action(p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_room public.quiz_rooms%rowtype;
  v_player public.quiz_players%rowtype;
  v_player_id uuid;
  v_token text;
  v_code text;
  v_name text;
  v_count integer;
  v_q public.quiz_questions%rowtype;
  v_answer integer;
  v_correct boolean;
  v_points integer;
  v_now timestamptz := clock_timestamp();
  v_new_round integer;
  v_candidate text;
begin
  if p_action = 'create_room' then
    v_name := left(trim(coalesce(p_data->>'name','')),18);
    if v_name = '' then return jsonb_build_object('error','Enter a player name.'); end if;
    loop
      v_candidate := '';
      for v_count in 1..4 loop
        v_candidate := v_candidate || chr(65 + floor(random()*26)::int);
      end loop;
      exit when not exists(select 1 from quiz_rooms where code=v_candidate);
    end loop;
    v_token := encode(gen_random_bytes(24),'hex');
    insert into quiz_rooms(code,status) values(v_candidate,'lobby') returning * into v_room;
    insert into quiz_players(room_id,display_name,is_host) values(v_room.id,v_name,true) returning * into v_player;
    update quiz_rooms set host_player_id=v_player.id where id=v_room.id;
    insert into quiz_player_sessions(player_id,token_hash) values(v_player.id,encode(digest(v_token,'sha256'),'hex'));
    return jsonb_build_object('code',v_candidate,'player_id',v_player.id,'token',v_token);
  elsif p_action = 'join_room' then
    v_code := upper(trim(coalesce(p_data->>'code','')));
    v_name := left(trim(coalesce(p_data->>'name','')),18);
    if v_name='' or v_code !~ '^[A-Z]{4}$' then return jsonb_build_object('error','Enter your name and a valid four-letter room code.'); end if;
    select * into v_room from quiz_rooms where code=v_code for update;
    if not found then return jsonb_build_object('error','Room not found. Check the code and try again.'); end if;
    select count(*) into v_count from quiz_players where room_id=v_room.id;
    if v_count >= 8 then return jsonb_build_object('error','This room is full (8 players).'); end if;
    v_token := encode(gen_random_bytes(24),'hex');
    insert into quiz_players(room_id,display_name,waiting_next_round)
      values(v_room.id,v_name,v_room.status in ('question','reveal')) returning * into v_player;
    insert into quiz_player_sessions(player_id,token_hash) values(v_player.id,encode(digest(v_token,'sha256'),'hex'));
    return jsonb_build_object('code',v_code,'player_id',v_player.id,'token',v_token,'state',public._quiz_state(v_room.id,v_player.id));
  elsif p_action in ('get_state','start_game','submit_answer','advance','play_again') then
    v_code := upper(trim(coalesce(p_data->>'code','')));
    begin v_player_id := (p_data->>'player_id')::uuid; exception when others then return jsonb_build_object('error','Invalid player session.'); end;
    v_token := coalesce(p_data->>'token','');
    select * into v_room from quiz_rooms where code=v_code for update;
    if not found then return jsonb_build_object('error','Room not found.'); end if;
    v_now := clock_timestamp();
    if not exists(select 1 from quiz_player_sessions where player_id=v_player_id and token_hash=encode(digest(v_token,'sha256'),'hex')) then
      return jsonb_build_object('error','This player session is not valid. Rejoin the room.');
    end if;
    select * into v_player from quiz_players where id=v_player_id and room_id=v_room.id;
    if not found then return jsonb_build_object('error','Player is not in this room.'); end if;

    if p_action = 'get_state' then
      return jsonb_build_object('state',public._quiz_state(v_room.id,v_player_id));
    elsif p_action = 'start_game' then
      if not v_player.is_host then return jsonb_build_object('error','Only the host can start the game.'); end if;
      if v_room.status not in ('lobby','finished') then return jsonb_build_object('error','A game is already in progress.'); end if;
      select count(*) into v_count from quiz_players where room_id=v_room.id;
      if v_count < 2 then return jsonb_build_object('error','At least 2 players are needed to start.'); end if;
      v_new_round := v_room.round_number + 1;
      if (select count(*) from quiz_questions q where not exists(select 1 from quiz_used_questions u where u.room_id=v_room.id and u.question_id=q.id)) < 12 then
        delete from quiz_used_questions where room_id=v_room.id;
      end if;
      delete from quiz_room_questions where room_id=v_room.id and round_number=v_new_round;
      insert into quiz_room_questions(room_id,round_number,question_order,question_id)
        select v_room.id,v_new_round,(row_number() over())::int-1,s.id
        from (select q.id from quiz_questions q
              where not exists(select 1 from quiz_used_questions u where u.room_id=v_room.id and u.question_id=q.id)
              order by random() limit 12) s;
      if (select count(*) from quiz_room_questions where room_id=v_room.id and round_number=v_new_round) < 12 then
        return jsonb_build_object('error','The question bank needs at least 12 unused questions.');
      end if;
      insert into quiz_used_questions(room_id,question_id)
        select v_room.id,question_id from quiz_room_questions where room_id=v_room.id and round_number=v_new_round
        on conflict do nothing;
      delete from quiz_answers where room_id=v_room.id and round_number=v_new_round;
      update quiz_players set score=0,waiting_next_round=false where room_id=v_room.id;
      update quiz_rooms set status='question',round_number=v_new_round,question_index=0,
        question_started_at=v_now,question_deadline=v_now+interval '20 seconds',reveal_at=null
        where id=v_room.id;
      return jsonb_build_object('state',public._quiz_state(v_room.id,v_player_id));
    elsif p_action = 'submit_answer' then
      if v_room.status <> 'question' then return jsonb_build_object('error','This question is already closed.'); end if;
      if v_player.waiting_next_round then return jsonb_build_object('error','You are waiting for the next round.'); end if;
      if v_now >= v_room.question_deadline then return jsonb_build_object('error','Time is up.'); end if;
      begin v_answer := (p_data->>'answer_index')::int; exception when others then return jsonb_build_object('error','Choose an answer.'); end;
      if v_answer < 0 or v_answer > 3 then return jsonb_build_object('error','Invalid answer.'); end if;
      select q.* into v_q from quiz_questions q join quiz_room_questions rq on rq.question_id=q.id
        where rq.room_id=v_room.id and rq.round_number=v_room.round_number and rq.question_order=v_room.question_index;
      v_correct := v_answer = v_q.correct_index;
      v_points := case when v_correct then 500 + round(500 * greatest(0,extract(epoch from (v_room.question_deadline-v_now))/20.0))::int else 0 end;
      insert into quiz_answers(room_id,round_number,question_order,player_id,option_index,is_correct,points,answered_at)
        values(v_room.id,v_room.round_number,v_room.question_index,v_player_id,v_answer,v_correct,v_points,v_now)
        on conflict do nothing;
      if not found then return jsonb_build_object('error','Your answer is already locked.'); end if;
      update quiz_players set score=score+v_points where id=v_player_id;
      select count(*) into v_count from quiz_players where room_id=v_room.id and not waiting_next_round;
      if (select count(*) from quiz_answers where room_id=v_room.id and round_number=v_room.round_number and question_order=v_room.question_index) >= v_count then
        update quiz_rooms set status='reveal',reveal_at=v_now where id=v_room.id;
      end if;
      return jsonb_build_object('state',public._quiz_state(v_room.id,v_player_id));
    elsif p_action = 'advance' then
      if v_room.status='question' and v_now >= v_room.question_deadline then
        update quiz_rooms set status='reveal',reveal_at=v_now where id=v_room.id;
      elsif v_room.status='reveal' and v_room.reveal_at is not null and v_now >= v_room.reveal_at+interval '4 seconds' then
        if v_room.question_index >= 11 then
          update quiz_rooms set status='finished' where id=v_room.id;
        else
          update quiz_rooms set status='question',question_index=question_index+1,
            question_started_at=v_now,question_deadline=v_now+interval '20 seconds',reveal_at=null
            where id=v_room.id;
        end if;
      end if;
      return jsonb_build_object('state',public._quiz_state(v_room.id,v_player_id));
    elsif p_action = 'play_again' then
      if not v_player.is_host then return jsonb_build_object('error','Only the host can start another round.'); end if;
      if v_room.status <> 'finished' then return jsonb_build_object('error','Finish the current round first.'); end if;
      update quiz_players set score=0,waiting_next_round=false where room_id=v_room.id;
      update quiz_rooms set status='lobby',question_index=0,question_started_at=null,question_deadline=null,reveal_at=null where id=v_room.id;
      return jsonb_build_object('state',public._quiz_state(v_room.id,v_player_id));
    end if;
  end if;
  return jsonb_build_object('error','Unknown action.');
end;
$$;

create or replace function public._quiz_state(p_room_id uuid,p_player_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r quiz_rooms%rowtype;
  q quiz_questions%rowtype;
  qjson jsonb := null;
  pjson jsonb;
  answered_count integer := 0;
begin
  select * into r from quiz_rooms where id=p_room_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'display_name',p.display_name,'score',p.score,'is_host',p.is_host,
    'waiting_next_round',p.waiting_next_round,
    'has_answered',exists(select 1 from quiz_answers a where a.room_id=r.id and a.round_number=r.round_number and a.question_order=r.question_index and a.player_id=p.id)
  ) order by p.joined_at),'[]'::jsonb) into pjson
  from quiz_players p where p.room_id=r.id;
  select count(*) into answered_count from quiz_answers where room_id=r.id and round_number=r.round_number and question_order=r.question_index;
  if r.status in ('question','reveal') then
    select qq.* into q from quiz_questions qq join quiz_room_questions rq on rq.question_id=qq.id
      where rq.room_id=r.id and rq.round_number=r.round_number and rq.question_order=r.question_index;
    qjson := jsonb_build_object('prompt',q.prompt,'category',q.category,'options',q.options);
    if r.status='reveal' then qjson := qjson || jsonb_build_object('correct_index',q.correct_index); end if;
  end if;
  return jsonb_build_object(
    'code',r.code,
    'status',case when exists(select 1 from quiz_players p where p.id=p_player_id and p.waiting_next_round) and r.status in ('question','reveal') then 'lobby' else r.status end,
    'global_status',r.status,'round_number',r.round_number,'question_index',r.question_index,
    'server_now',clock_timestamp(),
    'deadline_at',case when exists(select 1 from quiz_players p where p.id=p_player_id and p.waiting_next_round) then null else r.question_deadline end,
    'reveal_until',case when r.reveal_at is null then null else r.reveal_at+interval '4 seconds' end,
    'players',pjson,'question',case when exists(select 1 from quiz_players p where p.id=p_player_id and p.waiting_next_round) then null else qjson end,
    'answered_count',answered_count,
    'active_count',(select count(*) from quiz_players where room_id=r.id and not waiting_next_round)
  );
end;
$$;

grant execute on function public.game_action(text,jsonb) to anon, authenticated, service_role;
grant execute on function public._quiz_state(uuid,uuid) to service_role;

insert into public.quiz_questions(category,prompt,options,correct_index) values
('Geography', 'What is the capital of Australia?', '["Sydney", "Canberra", "Melbourne", "Perth"]'::jsonb, 1),
('Geography', 'Which country is home to the city of Kyoto?', '["China", "Thailand", "Japan", "South Korea"]'::jsonb, 2),
('Geography', 'Which is the largest ocean on Earth?', '["Atlantic Ocean", "Indian Ocean", "Arctic Ocean", "Pacific Ocean"]'::jsonb, 3),
('Geography', 'The Andes mountain range is mainly in which continent?', '["South America", "Europe", "Africa", "Asia"]'::jsonb, 0),
('Geography', 'Which river flows through Egypt?', '["Amazon", "Danube", "Nile", "Yangtze"]'::jsonb, 2),
('Geography', 'What is the smallest continent by land area?', '["Europe", "Australia", "Antarctica", "South America"]'::jsonb, 1),
('History', 'In which year did the first Moon landing take place?', '["1965", "1967", "1969", "1972"]'::jsonb, 2),
('History', 'The ancient city of Petra is located in which country?', '["Jordan", "Greece", "Turkey", "Egypt"]'::jsonb, 0),
('History', 'Who was the first person to walk on the Moon?', '["Buzz Aldrin", "Yuri Gagarin", "Michael Collins", "Neil Armstrong"]'::jsonb, 3),
('History', 'Which civilization built Machu Picchu?', '["Maya", "Inca", "Aztec", "Roman"]'::jsonb, 1),
('History', 'The Renaissance began in which country?', '["France", "England", "Italy", "Spain"]'::jsonb, 2),
('History', 'Which document begins with the words “We the People”?', '["Magna Carta", "U.S. Constitution", "Declaration of Independence", "Bill of Rights"]'::jsonb, 1),
('Science', 'What gas do plants absorb from the atmosphere?', '["Oxygen", "Nitrogen", "Carbon dioxide", "Hydrogen"]'::jsonb, 2),
('Science', 'How many bones are typically in an adult human body?', '["186", "206", "226", "246"]'::jsonb, 1),
('Science', 'Which planet is known as the Red Planet?', '["Venus", "Jupiter", "Mars", "Mercury"]'::jsonb, 2),
('Science', 'What is the chemical symbol for gold?', '["Ag", "Gd", "Go", "Au"]'::jsonb, 3),
('Science', 'What force keeps planets in orbit around the Sun?', '["Magnetism", "Gravity", "Friction", "Electricity"]'::jsonb, 1),
('Science', 'At sea level, water boils at what temperature in Celsius?', '["90°C", "95°C", "100°C", "110°C"]'::jsonb, 2),
('Nature', 'What is the largest mammal in the world?', '["African elephant", "Blue whale", "Giraffe", "Orca"]'::jsonb, 1),
('Nature', 'Which animal is known for changing its color to blend in?', '["Chameleon", "Penguin", "Koala", "Meerkat"]'::jsonb, 0),
('Nature', 'What is the fastest land animal?', '["Lion", "Horse", "Cheetah", "Gazelle"]'::jsonb, 2),
('Nature', 'Which part of a plant usually absorbs water from the soil?', '["Leaves", "Flowers", "Roots", "Stem"]'::jsonb, 2),
('Nature', 'What is a baby frog called?', '["Cub", "Tadpole", "Calf", "Chick"]'::jsonb, 1),
('Nature', 'How many legs does a spider have?', '["Six", "Eight", "Ten", "Twelve"]'::jsonb, 1),
('Sports', 'How many players from one soccer team are on the field at a time?', '["9", "10", "11", "12"]'::jsonb, 2),
('Sports', 'In tennis, what is a score of zero called?', '["Nil", "Love", "Blank", "Duck"]'::jsonb, 1),
('Sports', 'The Olympic Games are traditionally held every how many years?', '["Two", "Three", "Four", "Five"]'::jsonb, 2),
('Sports', 'Which sport uses a shuttlecock?', '["Squash", "Badminton", "Table tennis", "Volleyball"]'::jsonb, 1),
('Sports', 'How many points is a touchdown worth in American football before the extra point?', '["3", "5", "6", "7"]'::jsonb, 2),
('Entertainment', 'Which instrument has 88 keys on a standard model?', '["Violin", "Piano", "Flute", "Harp"]'::jsonb, 1),
('Entertainment', 'What is the name of the fictional school in the Harry Potter series?', '["Nevermore", "Hogwarts", "Rivendell", "Xavier’s School"]'::jsonb, 1),
('Entertainment', 'Which artist painted the Mona Lisa?', '["Vincent van Gogh", "Pablo Picasso", "Leonardo da Vinci", "Claude Monet"]'::jsonb, 2),
('Food & Culture', 'Sushi is traditionally associated with which country?', '["Japan", "Vietnam", "India", "Mexico"]'::jsonb, 0),
('Food & Culture', 'Which spice is known for giving many curry dishes a yellow color?', '["Cinnamon", "Turmeric", "Paprika", "Nutmeg"]'::jsonb, 1),
('Food & Culture', 'What is the main ingredient in traditional hummus?', '["Lentils", "Chickpeas", "Black beans", "Peas"]'::jsonb, 1)
on conflict do nothing;

 
insert into public.quiz_questions(category,prompt,options,correct_index)
values ('Geography', 'What is the capital of Portugal?', '["Porto", "Lisbon", "Madrid", "Seville"]'::jsonb, 1);
