import React, { useCallback, useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { createClient } from "@supabase/supabase-js";
import "./styles.css";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseKey = import.meta.env.VITE_SUPABASE_ANON_KEY;
const supabase = supabaseUrl && supabaseKey ? createClient(supabaseUrl, supabaseKey) : null;
const letters = ["A", "B", "C", "D"];

function App() {
  const [theme, setTheme] = useState("dark");
  const [screen, setScreen] = useState("home");
  const [name, setName] = useState("");
  const [joinCode, setJoinCode] = useState("");
  const [room, setRoom] = useState(null);
  const [playerId, setPlayerId] = useState(null);
  const [token, setToken] = useState(null);
  const [state, setState] = useState(null);
  const [choice, setChoice] = useState(null);
  const [seconds, setSeconds] = useState(20);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const [serverOffset, setServerOffset] = useState(0);

  const api = useCallback(async (action, data = {}) => {
    if (!supabase) throw new Error("Add the Supabase URL and publishable key in Vercel environment variables.");
    const { data: result, error: invokeError } = await supabase.functions.invoke("game-api", { body: { action, ...data } });
    if (invokeError) throw new Error(invokeError.message || "Could not contact the game server.");
    if (result?.error) throw new Error(result.error);
    return result;
  }, []);

  const applyState = useCallback((next) => {
    if (!next) return;
    setState(next);
    if (next.server_now) setServerOffset(new Date(next.server_now).getTime() - Date.now());
    setScreen(next.status === "finished" ? "finished" : next.status === "lobby" ? "lobby" : next.status === "reveal" ? "reveal" : "question");
  }, []);

  const refresh = useCallback(async () => {
    if (!room || !playerId || !token) return;
    try {
      const next = await api("get_state", { code: room.code, player_id: playerId, token });
      applyState(next);
    } catch (e) { setError(e.message); }
  }, [room, playerId, token, api, applyState]);

  const perform = async (action, data = {}) => {
    setBusy(true); setError("");
    try {
      const result = await api(action, { code: room?.code, player_id: playerId, token, ...data });
      if (result?.state) applyState(result.state);
      else if (result?.status) applyState(result);
      else await refresh();
      return result;
    } catch (e) { setError(e.message); return null; }
    finally { setBusy(false); }
  };

  const createRoom = async () => {
    if (!name.trim()) return setError("Enter your name first.");
    setBusy(true); setError("");
    try {
      const result = await api("create_room", { name: name.trim() });
      setRoom({ code: result.code }); setPlayerId(result.player_id); setToken(result.token);
      applyState(result.state); setScreen("lobby");
    } catch (e) { setError(e.message); }
    finally { setBusy(false); }
  };

  const joinRoom = async () => {
    if (!name.trim() || joinCode.trim().length !== 4) return setError("Enter your name and the four-letter room code.");
    setBusy(true); setError("");
    try {
      const result = await api("join_room", { name: name.trim(), code: joinCode.trim().toUpperCase() });
      setRoom({ code: result.code }); setPlayerId(result.player_id); setToken(result.token);
      applyState(result.state); setScreen(result.state?.status === "lobby" ? "lobby" : "waiting");
    } catch (e) { setError(e.message); }
    finally { setBusy(false); }
  };

  useEffect(() => {
    if (!room || !playerId || !token || !supabase) return;
    const channel = supabase.channel(`room:${room.code}`).on("broadcast", { event: "state_changed" }, refresh).subscribe();
    const poll = setInterval(refresh, 1800);
    refresh();
    return () => { clearInterval(poll); supabase.removeChannel(channel); };
  }, [room, playerId, token, refresh]);

  useEffect(() => {
    if (!state || !["question", "reveal"].includes(screen)) return;
    const tick = () => {
      const deadline = state.deadline_at ? new Date(state.deadline_at).getTime() : Date.now() + 20000;
      const remaining = Math.max(0, Math.ceil((deadline - (Date.now() + serverOffset)) / 1000));
      setSeconds(remaining);
      if (remaining === 0 && screen === "question") perform("advance");
    };
    tick();
    const timer = setInterval(tick, 250);
    return () => clearInterval(timer);
  }, [state?.deadline_at, screen, serverOffset]);

  useEffect(() => {
    if (screen === "reveal" && state?.reveal_until) {
      const remaining = new Date(state.reveal_until).getTime() - (Date.now() + serverOffset);
      const timer = setTimeout(() => perform("advance"), Math.max(0, remaining));
      return () => clearTimeout(timer);
    }
  }, [screen, state?.reveal_until, serverOffset]);

  const players = state?.players || [];
  const isHost = state?.host_player_id === playerId;
  const answered = state?.my_answer != null;
  const leaderboard = useMemo(() => [...players].sort((a, b) => b.score - a.score), [players]);

  const choose = async (index) => {
    if (choice != null || answered || screen !== "question") return;
    setChoice(index);
    await perform("answer", { answer_index: index });
    await refresh();
  };

  const copyRoom = async () => {
    try { await navigator.clipboard.writeText(room.code); setCopied(true); setTimeout(() => setCopied(false), 1400); }
    catch { setError("Copy failed. You can select the room code manually."); }
  };

  const start = () => perform("start_game");
  const playAgain = () => { setChoice(null); perform("play_again"); };
  const myName = players.find(p => p.id === playerId)?.name || name;

  return <div className={`app ${theme}`}>
    <header className="topbar"><div className="brand"><span className="brand-mark">⚡</span> QUIZ <b>RACE</b></div><button className="theme-toggle" onClick={() => setTheme(theme === "dark" ? "light" : "dark")}>{theme === "dark" ? "☀ Light" : "☾ Dark"}</button></header>
    {error && <div className="error">{error}<button onClick={() => setError("")}>×</button></div>}
    {screen === "home" && <main className="shell">
      <section className="hero"><div className="eyebrow">FAST MINDS. BIG POINTS.</div><h1>Ready, set,<br/><span>QUIZ RACE.</span></h1><p className="subhead">A little knowledge. A lot of competition.</p></section>
      <section className="home-card">
        <div className="form-block"><label>YOUR PLAYER NAME</label><input maxLength="18" placeholder="Enter your name" value={name} onChange={e => setName(e.target.value)}/><button className="primary full" disabled={busy || !name.trim()} onClick={createRoom}>{busy ? "Creating..." : "Create a room"}</button></div>
        <div className="or">OR JOIN A ROOM</div>
        <div className="form-block"><label>FOUR-LETTER ROOM CODE</label><input className="code-input" maxLength="4" placeholder="ABCD" value={joinCode} onChange={e => setJoinCode(e.target.value.toUpperCase().replace(/[^A-Z]/g,""))}/><button className="secondary full" disabled={busy || !name.trim() || joinCode.length !== 4} onClick={joinRoom}>Join room</button></div>
      </section>
      <div className="rules"><span>✦ 2–8 PLAYERS</span><span>✦ 12 QUESTIONS</span><span>✦ 20 SECONDS</span><span>✦ NO SIGN-UP</span></div>
      <footer>MADE FOR FRIENDLY COMPETITION <span>•</span> QUIZ RACE LITE</footer>
    </main>}

    {screen === "lobby" && <main className="shell"><section className="panel">
      <div className="eyebrow">ROOM LOBBY</div><h1>You're in.</h1><p className="muted">Share this code with your friends</p><div className="room-code">{room?.code}</div><button className="copy-link" onClick={copyRoom}>{copied ? "Copied!" : "Copy room code ↗"}</button>
      <div className="player-list"><div className="section-head"><span>PLAYERS</span><span className="live-dot">● LIVE · {players.length}/8</span></div>{players.map(p => <div className="player-row" key={p.id}><span className="avatar">{p.name?.[0]?.toUpperCase()}</span><b>{p.name}</b>{p.id === state.host_player_id && <span className="host-tag">HOST</span>}{p.id === playerId && <span className="you-tag">YOU</span>}</div>)}</div>
      {isHost ? <button className="primary full" disabled={busy || players.length < 2} onClick={start}>{busy ? "Starting..." : players.length < 2 ? "Waiting for players..." : "Start game →"}</button> : <p className="muted">Waiting for the host to start the game…</p>}
    </section></main>}

    {screen === "waiting" && <main className="shell"><section className="panel"><div className="eyebrow">NEXT ROUND</div><h1>You're on deck.</h1><p className="muted">This game is already in progress. You'll join the next round.</p><div className="player-list"><div className="section-head">PLAYERS IN ROOM</div>{players.map(p => <div className="player-row" key={p.id}><span className="avatar">{p.name?.[0]?.toUpperCase()}</span><b>{p.name}</b></div>)}</div></section></main>}

    {["question","reveal"].includes(screen) && state && <main className="shell"><section className="game-panel">
      <div className="game-meta"><span>QUESTION {state.question_number || 1} / 12</span><span>{state.category || "GENERAL KNOWLEDGE"}</span></div>
      <div className="timer-wrap"><div className="timer-number">{seconds}<small>s</small></div><div className="timer-track"><div className="timer-fill" style={{width:`${seconds/20*100}%`}}/></div></div>
      <h2>{state.question?.question || "Get ready…"}</h2>
      <div className="answers">{(state.question?.options || []).map((answer,i) => <button key={i} className={`answer ${choice===i || state.my_answer===i ? "selected":""}`} disabled={screen==="reveal" || answered || choice!==null} onClick={() => choose(i)}><span className="answer-letter">{letters[i]}</span>{answer}{(choice===i || state.my_answer===i) && <span className="answer-check">✓</span>}</button>)}</div>
      {screen === "question" ? <div className="answer-status">{answered || choice!==null ? "Answer locked — good luck!" : "Choose your answer before time runs out"}</div> : <><div className="correct-box"><span className="correct-label">CORRECT ANSWER</span><b>{state.question?.options?.[state.question?.correct_index]}</b></div><div className="leaderboard"><div className="section-head"><span>LIVE LEADERBOARD</span><span>POINTS</span></div>{leaderboard.map((p,i)=><div className={`leader-row ${p.id===playerId?"mine":""}`} key={p.id}><span className="rank">{["🥇","🥈","🥉"][i] || `#${i+1}`}</span><b>{p.name}{p.id===playerId?" (you)":""}</b><strong>{p.score}</strong></div>)}</div><div className="answer-status">Next question coming up…</div></>}
      <div className="mini-players">{players.map(p=><span className="mini-player" key={p.id}>{p.name}: {p.answered ? "✓" : "…"}</span>)}</div>
    </section></main>}

    {screen === "finished" && <main className="shell"><section className="panel winner-panel"><div className="trophy">🏆</div><div className="eyebrow">GAME COMPLETE</div><h1>{leaderboard[0]?.name || "Winner"} wins!</h1><p className="muted">A brilliant race. Here's the final leaderboard.</p><div className="leaderboard">{leaderboard.map((p,i)=><div className={`leader-row ${p.id===playerId?"mine":""}`} key={p.id}><span className="rank">{["🥇","🥈","🥉"][i] || `#${i+1}`}</span><b>{p.name}{p.id===playerId?" (you)":""}</b><strong>{p.score}</strong></div>)}</div>{isHost ? <button className="primary full" disabled={busy} onClick={playAgain}>Play again ↻</button> : <p className="muted">Waiting for the host to start another round…</p>}</section></main>}
  </div>;
}

createRoot(document.getElementById("root")).render(<App />);
