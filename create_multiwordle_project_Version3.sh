#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="multiwordle"
echo "Creating project in ./${ROOT_DIR}/ ..."
mkdir -p "${ROOT_DIR}"

# docker-compose.yml
cat > "${ROOT_DIR}/docker-compose.yml" <<'EOF'
version: "3.8"
services:
  db:
    image: mysql:8
    environment:
      MYSQL_ROOT_PASSWORD: password
      MYSQL_DATABASE: wordle
    ports:
      - "3306:3306"
    volumes:
      - db_data:/var/lib/mysql
  redis:
    image: redis:7
    ports:
      - "6379:6379"
  backend:
    build:
      context: ./backend
    command: python app.py
    depends_on:
      - db
      - redis
    environment:
      - MYSQL_URL=mysql+pymysql://root:password@db:3306/wordle
      - REDIS_URL=redis://redis:6379/0
      - SECRET_KEY=devkey
    ports:
      - "5000:5000"
    volumes:
      - ./backend:/app
  frontend:
    image: node:18
    working_dir: /app
    volumes:
      - ./frontend:/app
    command: sh -c "npm install && npm run dev -- --host 0.0.0.0"
    ports:
      - "5173:5173"
volumes:
  db_data:
EOF

# .env.example
cat > "${ROOT_DIR}/.env.example" <<'EOF'
MYSQL_URL=mysql+pymysql://root:password@db:3306/wordle
REDIS_URL=redis://redis:6379/0
SECRET_KEY=devkey
EOF

# .gitignore
cat > "${ROOT_DIR}/.gitignore" <<'EOF'
/node_modules
/frontend/node_modules
/backend/__pycache__
.env
EOF

# README.md
cat > "${ROOT_DIR}/README.md" <<'EOF'
# Multiplayer Wordle (Flask + Socket.IO + React)

This starter implements a two-player Wordle-like game with both simultaneous "race" and "turn"-based modes, server-side validation, per-player 15s timers, and real-time updates via Socket.IO.

Quick start (dev)
1. Build & run with Docker Compose (recommended):
   docker-compose up --build

2. Initialize DB (once MySQL is ready):
   - Connect to the MySQL container and run:
     mysql -uroot -ppassword wordle < backend/schema.sql
     mysql -uroot -ppassword wordle < backend/load_words.sql

3. Frontend:
   - Vite dev server runs at http://localhost:5173 (docker-compose maps port 5173).
   - Backend runs at http://localhost:5000.

Notes
- This prototype keeps in-memory match state and timers in the backend process. For multi-worker production, move match state and timers to a shared store (Redis) or a dedicated coordinator service.
- The server enforces a 15s timeout per player. On timeout, the server emits a `guess_timeout` event and updates match_state; in turn mode it advances the turn, in race mode it records a timeout entry for that player.
- Authentication is minimal (username-based). Replace with JWT/session auth for production.

Socket events (summary)
- create_game { username, mode } -> game_created { room, user_id }
- join_game { username, room } -> joined { room, user_id, state } + player_joined broadcast
- start_match { room } -> match_started broadcast
- player_guess { room, user_id, guess } -> guess_result + match_state (and match_over if winner)
- guess_timeout broadcast when a timeout occurs
EOF

# Backend files
mkdir -p "${ROOT_DIR}/backend"

cat > "${ROOT_DIR}/backend/requirements.txt" <<'EOF'
flask
flask-socketio
python-socketio
eventlet
flask-sqlalchemy
pymysql
redis
python-dotenv
EOF

cat > "${ROOT_DIR}/backend/Dockerfile" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "app.py"]
EOF

cat > "${ROOT_DIR}/backend/app.py" <<'EOF'
import os
import eventlet
eventlet.monkey_patch()

from flask import Flask, request, jsonify, send_from_directory
from flask_socketio import SocketIO, emit, join_room, leave_room
from models import db, User, Word, Match, Guess
from game import GameManager
from dotenv import load_dotenv

load_dotenv()

MYSQL_URL = os.environ.get("MYSQL_URL", "mysql+pymysql://root:password@db:3306/wordle")
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
SECRET_KEY = os.environ.get("SECRET_KEY", "devkey")

app = Flask(__name__, static_folder="../frontend/dist", static_url_path="/")
app.config['SQLALCHEMY_DATABASE_URI'] = MYSQL_URL
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SECRET_KEY'] = SECRET_KEY

# Use Redis as message queue for Socket.IO broadcasts across workers
socketio = SocketIO(app, cors_allowed_origins="*", message_queue=REDIS_URL)
db.init_app(app)

# Game manager with broadcaster so it can emit timeouts/state changes
game_manager = GameManager(db_session=lambda: db.session, broadcaster=socketio)

@app.route('/api/words/validate', methods=['POST'])
def validate_word():
    data = request.json or {}
    w = (data.get('word') or '').lower()
    valid = Word.query.filter_by(word=w).first() is not None
    return jsonify({'valid': bool(valid)}), 200

# Serve built frontend if exists
@app.route('/')
def index():
    dist_index = os.path.join(app.static_folder, 'index.html')
    if os.path.exists(dist_index):
        return send_from_directory(app.static_folder, 'index.html')
    return jsonify({"message": "Backend running. No frontend build found."})

#
# Socket.IO event handlers
#
@socketio.on('create_game')
def on_create_game(data):
    username = (data.get('username') or f'player{os.urandom(2).hex()}').strip()
    mode = data.get('mode', 'race')
    user = User.get_or_create(username)
    room = game_manager.create_match(user.id, mode)
    join_room(room)
    # Return creator info (room and their numeric user id)
    emit('game_created', {'room': room, 'mode': mode, 'user_id': user.id}, room=request.sid)
    app.logger.info(f"create_game: user={user.username} id={user.id} room={room} mode={mode}")

@socketio.on('join_game')
def on_join_game(data):
    username = (data.get('username') or f'player{os.urandom(2).hex()}').strip()
    room = data.get('room')
    user = User.get_or_create(username)
    ok, payload = game_manager.join_match(room, user.id)
    if not ok:
        emit('error', {'message': payload})
        return
    join_room(room)
    # Send joining client their id and current state
    emit('joined', {'room': room, 'user_id': user.id, 'state': game_manager.get_state(room)}, room=request.sid)
    # Broadcast to room that a player joined (include usernames)
    socketio.emit('player_joined', {'room': room, 'players': payload.get('players', [])}, room=room)
    app.logger.info(f"join_game: user={user.username} id={user.id} room={room} payload={payload}")
    # Auto-start if ready (server-side policy)
    if payload.get('ready_to_start'):
        ok2, msg = game_manager.start_match(room)
        if ok2:
            socketio.emit('match_started', game_manager.get_state(room), room=room)
        else:
            socketio.emit('error', {'message': msg}, room=room)

@socketio.on('start_match')
def on_start_match(data):
    room = data.get('room')
    timeout_seconds = data.get('timeout_seconds')  # optional
    ok, msg = game_manager.start_match(room, timeout_seconds)
    if not ok:
        emit('error', {'message': msg})
        return
    socketio.emit('match_started', game_manager.get_state(room), room=room)

@socketio.on('player_guess')
def on_player_guess(data):
    room = data.get('room')
    user_id = data.get('user_id')
    guess = (data.get('guess') or '').lower()
    if not room or not user_id or not guess:
        emit('guess_error', {'message': 'invalid_payload'})
        return
    app.logger.info(f"player_guess: room={room} user_id={user_id} guess={guess}")
    result = game_manager.handle_guess(room, user_id, guess)
    if result.get('error'):
        emit('guess_error', {'message': result['error']})
        return
    # The GameManager already broadcasts guess_result and match_state when it has a broadcaster
    # but we also ensure the joining socket receives the immediate result
    emit('guess_ack', result['guess_result'], room=request.sid)

@socketio.on('disconnect')
def on_disconnect():
    # optional: mark player disconnected or start a short grace timer for reconnection
    app.logger.info(f"disconnect: sid={request.sid}")
    # For brevity we don't implement full disconnect handling here.

if __name__ == "__main__":
    with app.app_context():
        db.create_all()
    socketio.run(app, host='0.0.0.0', port=5000)
EOF

cat > "${ROOT_DIR}/backend/models.py" <<'EOF'
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime

db = SQLAlchemy()

class User(db.Model):
    __tablename__ = 'users'
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @staticmethod
    def get_or_create(username):
        s = db.session
        u = s.query(User).filter_by(username=username).first()
        if not u:
            u = User(username=username)
            s.add(u); s.commit()
        return u

class Word(db.Model):
    __tablename__ = 'words'
    id = db.Column(db.Integer, primary_key=True)
    word = db.Column(db.String(5), unique=True, nullable=False)

class Match(db.Model):
    __tablename__ = 'matches'
    id = db.Column(db.Integer, primary_key=True)
    room_id = db.Column(db.String(36), unique=True, nullable=False)
    mode = db.Column(db.String(10))
    target = db.Column(db.String(5))
    winner_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class Guess(db.Model):
    __tablename__ = 'guesses'
    id = db.Column(db.Integer, primary_key=True)
    match_room = db.Column(db.String(36), db.ForeignKey('matches.room_id'))
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'))
    word = db.Column(db.String(5))
    feedback = db.Column(db.String(255))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
EOF

cat > "${ROOT_DIR}/backend/game.py" <<'EOF'
import uuid
import time
import eventlet
from collections import defaultdict
from sqlalchemy.exc import SQLAlchemyError
from threading import Lock
from sqlalchemy.sql import func

from models import Match, Guess, Word, User

DEFAULT_TIMEOUT = 15.0  # seconds per guess/turn

class MatchState:
    def __init__(self, room_id, mode='race'):
        self.room_id = room_id
        self.mode = mode
        self.players = []  # ordered list of player ids (ints)
        self.guesses = defaultdict(list)  # player_id -> list of {'word','feedback','ts','timeout':bool}
        self.target = None
        self.turn_index = 0
        self.started = False
        self.finished = False
        self.winner = None
        self.lock = Lock()
        # timer-related
        self.timer_handles = {}     # player_id -> eventlet Timer-like object
        self.timed_out_players = set()
        self.timeout_seconds = DEFAULT_TIMEOUT

class GameManager:
    def __init__(self, db_session, broadcaster=None):
        """
        db_session: callable returning a SQLAlchemy session (e.g., lambda: db.session)
        broadcaster: object with .emit(event, payload, room=room) (e.g., socketio)
        """
        self.sessions = {}  # room_id -> MatchState
        self.db_session = db_session
        self.broadcaster = broadcaster

    def _summarize_state(self, ms: MatchState):
        # Compose players array with {id, username} in the stored ordering
        db = self.db_session()
        users = db.query(User).filter(User.id.in_(ms.players)).all() if ms.players else []
        user_map = {u.id: u.username for u in users}
        players_list = [{'id': pid, 'username': user_map.get(pid, f'player{pid}')} for pid in ms.players]
        # Convert guesses keys to strings for JSON stability
        guesses_serializable = {str(pid): ms.guesses[pid] for pid in ms.guesses}
        return {
            'room': ms.room_id,
            'mode': ms.mode,
            'players': players_list,
            'started': ms.started,
            'finished': ms.finished,
            'turn_index': ms.turn_index,
            'winner': ms.winner,
            'guesses': guesses_serializable
        }

    def create_match(self, host_user_id, mode='race'):
        room = str(uuid.uuid4())
        ms = MatchState(room, mode)
        ms.players.append(host_user_id)
        self.sessions[room] = ms
        return room

    def join_match(self, room, user_id):
        if room not in self.sessions:
            return False, "Room not found"
        ms = self.sessions[room]
        with ms.lock:
            if user_id in ms.players:
                return True, self._summarize_state(ms)
            if len(ms.players) >= 2:
                return False, "Room full"
            ms.players.append(user_id)
        return True, {'players': [ {'id': pid} for pid in ms.players ], 'ready_to_start': len(ms.players) >= 2}

    def start_match(self, room, timeout_seconds=None):
        if room not in self.sessions:
            return False, "Room not found"
        ms = self.sessions[room]
        with ms.lock:
            if ms.started:
                return False, "Already started"
            db = self.db_session()
            w = db.query(Word).order_by(func.rand()).first()
            if not w:
                return False, "No words in DB"
            ms.target = w.word
            ms.started = True
            if timeout_seconds:
                ms.timeout_seconds = float(timeout_seconds)
            # persist match
            try:
                m = Match(room_id=room, mode=ms.mode, target=ms.target)
                db.add(m); db.commit()
            except SQLAlchemyError:
                db.rollback()

            # Start timers:
            if ms.mode == 'turn':
                current_player = ms.players[ms.turn_index] if ms.players else None
                if current_player is not None:
                    self._start_turn_timer(room, current_player)
            else:  # race
                for p in ms.players:
                    self._start_player_timer(room, p)
        return True, "started"

    def _start_player_timer(self, room, player_id):
        ms = self.sessions.get(room)
        if not ms:
            return
        # cancel existing
        if player_id in ms.timer_handles and ms.timer_handles[player_id]:
            try:
                ms.timer_handles[player_id].cancel()
            except Exception:
                pass
        # schedule new timer using eventlet.spawn_after
        handle = eventlet.spawn_after(ms.timeout_seconds, self._handle_player_timeout, room, player_id)
        ms.timer_handles[player_id] = handle

    def _start_turn_timer(self, room, player_id):
        self._start_player_timer(room, player_id)

    def _cancel_all_timers(self, ms: MatchState):
        for h in list(ms.timer_handles.values()):
            try:
                h.cancel()
            except Exception:
                pass
        ms.timer_handles.clear()

    def _handle_player_timeout(self, room, player_id):
        ms = self.sessions.get(room)
        if not ms:
            return
        with ms.lock:
            if ms.finished:
                return
            # If the player's timer fired but they already acted (timer canceled), the handle may still call; check presence
            if player_id not in ms.players:
                return
            ms.timed_out_players.add(player_id)
            ts = time.time()
            ms.guesses[player_id].append({'word': None, 'feedback': ['timeout'] * 5, 'ts': ts, 'timeout': True})
            payload = {'room': room, 'player_id': player_id, 'message': 'timeout', 'timestamp': ts}
            if self.broadcaster:
                try:
                    self.broadcaster.emit('guess_timeout', payload, room=room)
                except Exception:
                    pass

            if ms.mode == 'turn':
                if ms.players:
                    ms.turn_index = (ms.turn_index + 1) % len(ms.players)
                    next_player = ms.players[ms.turn_index]
                    self._start_turn_timer(room, next_player)
                    if self.broadcaster:
                        try:
                            self.broadcaster.emit('match_state', self._summarize_state(ms), room=room)
                        except Exception:
                            pass
            else:
                # race: remove this player's timer handle so it won't fire again
                if player_id in ms.timer_handles:
                    try:
                        del ms.timer_handles[player_id]
                    except Exception:
                        pass
                if self.broadcaster:
                    try:
                        self.broadcaster.emit('match_state', self._summarize_state(ms), room=room)
                    except Exception:
                        pass

    def handle_guess(self, room, user_id, guess):
        if room not in self.sessions:
            return {'error': 'room_not_found'}
        ms = self.sessions[room]
        with ms.lock:
            db = self.db_session()
            if not db.query(Word).filter_by(word=guess).first():
                return {'error': 'invalid_word'}
            if ms.finished:
                return {'error': 'match_already_finished'}
            if user_id not in ms.players:
                return {'error': 'not_in_match'}
            if ms.mode == 'turn' and ms.players[ms.turn_index] != user_id:
                return {'error': 'not_your_turn'}

            feedback = self._score_guess(guess, ms.target)
            ts = time.time()
            ms.guesses[user_id].append({'word': guess, 'feedback': feedback, 'ts': ts, 'timeout': False})

            # persist guess (best-effort)
            try:
                g = Guess(match_room=room, user_id=user_id, word=guess, feedback=','.join(feedback))
                db.add(g); db.commit()
            except SQLAlchemyError:
                db.rollback()

            # cancel this player's timer (if any)
            try:
                if user_id in ms.timer_handles:
                    ms.timer_handles[user_id].cancel()
                    del ms.timer_handles[user_id]
            except Exception:
                pass

            result = {'guess_result': {'user_id': user_id, 'word': guess, 'feedback': feedback}}

            if guess == ms.target:
                ms.finished = True
                ms.winner = user_id
                result['match_over'] = {'winner': user_id, 'target': ms.target}
                self._cancel_all_timers(ms)
                try:
                    match = db.query(Match).filter_by(room_id=room).first()
                    if match:
                        match.winner_id = user_id
                        db.commit()
                except SQLAlchemyError:
                    db.rollback()
                # Broadcast outcome
                if self.broadcaster:
                    try:
                        self.broadcaster.emit('guess_result', result['guess_result'], room=room)
                        self.broadcaster.emit('match_state', self._summarize_state(ms), room=room)
                        self.broadcaster.emit('match_over', {'winner': user_id, 'target': ms.target}, room=room)
                    except Exception:
                        pass
                return result
            else:
                # For turn mode, advance turn and start new timer
                if ms.mode == 'turn':
                    if ms.players:
                        ms.turn_index = (ms.turn_index + 1) % len(ms.players)
                        next_player = ms.players[ms.turn_index]
                        self._start_turn_timer(room, next_player)
                else:
                    # In race, restart this player's timer for their next attempt
                    self._start_player_timer(room, user_id)

                # Broadcast guess_result and state
                if self.broadcaster:
                    try:
                        self.broadcaster.emit('guess_result', result['guess_result'], room=room)
                        self.broadcaster.emit('match_state', self._summarize_state(ms), room=room)
                    except Exception:
                        pass
                return result

    def get_state(self, room):
        ms = self.sessions.get(room)
        if not ms:
            return {}
        return self._summarize_state(ms)

    def _score_guess(self, guess, target):
        # Wordle scoring: 'correct', 'present', 'absent'
        feedback = ['absent'] * len(guess)
        target_chars = list(target)
        for i, ch in enumerate(guess):
            if target[i] == ch:
                feedback[i] = 'correct'
                target_chars[i] = None
        for i, ch in enumerate(guess):
            if feedback[i] == 'correct':
                continue
            if ch in target_chars:
                feedback[i] = 'present'
                target_chars[target_chars.index(ch)] = None
        return feedback
EOF

cat > "${ROOT_DIR}/backend/schema.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(80) UNIQUE NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS words (
  id INT AUTO_INCREMENT PRIMARY KEY,
  word CHAR(5) UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS matches (
  id INT AUTO_INCREMENT PRIMARY KEY,
  room_id VARCHAR(36) UNIQUE NOT NULL,
  mode VARCHAR(10),
  target CHAR(5),
  winner_id INT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS guesses (
  id INT AUTO_INCREMENT PRIMARY KEY,
  match_room VARCHAR(36),
  user_id INT,
  word CHAR(5),
  feedback TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF

cat > "${ROOT_DIR}/backend/load_words.sql" <<'EOF'
-- Small sample list; replace with a full 5-letter dictionary in production
INSERT INTO words (word) VALUES ('cigar'), ('apple'), ('other'), ('about'), ('zebra'), ('crate'), ('slate'), ('flint'), ('pride'), ('grace');
EOF

# Frontend files
mkdir -p "${ROOT_DIR}/frontend/src/components"

cat > "${ROOT_DIR}/frontend/package.json" <<'EOF'
{
  "name": "multiplayer-wordle-frontend",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "socket.io-client": "^4.6.1"
  },
  "devDependencies": {
    "vite": "^5.2.0"
  }
}
EOF

cat > "${ROOT_DIR}/frontend/vite.config.js" <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    host: true
  }
})
EOF

cat > "${ROOT_DIR}/frontend/index.html" <<'EOF'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Multiplayer Wordle</title>
    <meta name="viewport" content="width=device-width,initial-scale=1.0" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat > "${ROOT_DIR}/frontend/src/main.jsx" <<'EOF'
import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './styles.css'

createRoot(document.getElementById('root')).render(<App />)
EOF

cat > "${ROOT_DIR}/frontend/src/socket.js" <<'EOF'
import { io } from "socket.io-client";

const BACKEND = import.meta.env.VITE_BACKEND_URL || "http://localhost:5000";
const socket = io(BACKEND, {
  autoConnect: true,
  transports: ["websocket"],
});

export default socket;
EOF

cat > "${ROOT_DIR}/frontend/src/App.jsx" <<'EOF'
import React, { useState, useEffect } from "react";
import socket from "./socket";
import GameBoard from "./components/GameBoard";
import Lobby from "./components/Lobby";

export default function App() {
  const [view, setView] = useState("lobby");
  const [room, setRoom] = useState(null);
  const [userId, setUserId] = useState(null);     // numeric DB id
  const [username, setUsername] = useState(null); // display name
  const [state, setState] = useState(null);
  const [notifications, setNotifications] = useState([]);

  useEffect(() => {
    socket.on("game_created", (data) => {
      setRoom(data.room);
      setUserId(data.user_id);
      setView("game");
    });

    socket.on("joined", (data) => {
      setRoom(data.room);
      setUserId(data.user_id);
      setState(data.state);
      setView("game");
    });

    socket.on("player_joined", (data) => {
      // request full state to update UI
      setTimeout(() => {
        socket.emit('noop'); // noop to keep connection alive; or request state endpoint if you add one
      }, 50);
    });

    socket.on("match_started", (s) => setState(s));
    socket.on("match_state", (s) => setState(s));
    socket.on("guess_result", (r) => {
      setNotifications((n) => [...n, `Guess: ${r.word} by ${r.user_id}`]);
    });
    socket.on("guess_ack", (r) => {
      setNotifications((n) => [...n, `Your guess acknowledged: ${r.word}`]);
    });
    socket.on("guess_error", (e) => {
      setNotifications((n) => [...n, `Error: ${e.message}`]);
    });
    socket.on("match_over", (m) => {
      setNotifications((n) => [...n, `Match over. Winner: ${m.winner}`]);
    });
    socket.on("guess_timeout", (t) => {
      setNotifications((n) => [...n, `Timeout: player ${t.player_id}`]);
    });

    return () => {
      socket.off("game_created");
      socket.off("joined");
      socket.off("player_joined");
      socket.off("match_started");
      socket.off("match_state");
      socket.off("guess_result");
      socket.off("guess_ack");
      socket.off("guess_error");
      socket.off("match_over");
      socket.off("guess_timeout");
    };
  }, []);

  function handleCreate(name, mode) {
    setUsername(name);
    socket.emit("create_game", { username: name, mode });
  }
  function handleJoin(name, roomId) {
    setUsername(name);
    socket.emit("join_game", { username: name, room: roomId });
  }

  return (
    <div className="app">
      {view === "lobby" && <Lobby onCreate={handleCreate} onJoin={handleJoin} />}
      {view === "game" && (
        <div>
          <GameBoard room={room} userId={userId} username={username} state={state} socket={socket} />
          <div className="notifications">
            <h4>Notifications</h4>
            <ul>
              {notifications.slice(-10).map((n, i) => <li key={i}>{n}</li>)}
            </ul>
          </div>
        </div>
      )}
    </div>
  );
}
EOF

cat > "${ROOT_DIR}/frontend/src/components/Lobby.jsx" <<'EOF'
import React, { useState } from "react";

export default function Lobby({ onCreate, onJoin }) {
  const [username, setUsername] = useState("");
  const [room, setRoom] = useState("");

  return (
    <div className="lobby">
      <h1>Multiplayer Wordle</h1>
      <input placeholder="Username" value={username} onChange={(e) => setUsername(e.target.value)} />
      <div className="row">
        <button onClick={() => onCreate(username || `p${Math.floor(Math.random()*1000)}`, "race")}>Create Race</button>
        <button onClick={() => onCreate(username || `p${Math.floor(Math.random()*1000)}`, "turn")}>Create Turn-based</button>
      </div>
      <div className="join">
        <input placeholder="Room ID" value={room} onChange={(e) => setRoom(e.target.value)} />
        <button onClick={() => onJoin(username || `p${Math.floor(Math.random()*1000)}`, room)}>Join</button>
      </div>
    </div>
  );
}
EOF

cat > "${ROOT_DIR}/frontend/src/components/GameBoard.jsx" <<'EOF'
import React, { useState, useEffect } from "react";
import VirtualKeyboard from "./VirtualKeyboard";

export default function GameBoard({ room, userId, username, state, socket }) {
  const [guess, setGuess] = useState("");
  const [localState, setLocalState] = useState(state);

  useEffect(() => setLocalState(state), [state]);

  function submitGuess() {
    if (!guess || guess.length !== 5) return alert("Enter 5 letters");
    if (!userId) return alert("User id not set yet. Wait a moment.");
    socket.emit("player_guess", { room, user_id: userId, guess });
    setGuess("");
  }

  const players = localState?.players || [];
  // Build a map of playerId -> guesses
  const guesses = localState?.guesses || {};

  return (
    <div className="game">
      <div className="game-header">
        <div>Room: {room}</div>
        <div>Mode: {localState?.mode}</div>
        <div>Players: {players.map(p => p.username).join(", ")}</div>
        <div>{localState?.finished ? `Finished. Winner: ${localState.winner}` : ""}</div>
      </div>

      <div className="boards">
        {players.map((p) => (
          <div className="player-board" key={p.id}>
            <h4>{p.username}{p.id === userId ? " (you)" : ""}</h4>
            <div className="grid">
              {(guesses[String(p.id)] || []).map((g, idx) => (
                <div className="row" key={idx}>
                  {Array.from({length:5}).map((_, i) => (
                    <div className={`cell ${g.feedback ? g.feedback[i] : ""}`} key={i}>
                      {g.word ? g.word[i].toUpperCase() : (g.timeout ? "—" : "")}
                    </div>
                  ))}
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>

      <div className="guess-entry">
        <input value={guess} maxLength={5} onChange={(e) => setGuess(e.target.value.toLowerCase())} />
        <button onClick={submitGuess}>Guess</button>
      </div>

      <VirtualKeyboard onType={(ch) => setGuess((s) => (s + ch).slice(0,5))} />
    </div>
  );
}
EOF

cat > "${ROOT_DIR}/frontend/src/components/VirtualKeyboard.jsx" <<'EOF'
import React from "react";

const keys = [
  "qwertyuiop",
  "asdfghjkl",
  "zxcvbnm"
];

export default function VirtualKeyboard({ onType }) {
  return (
    <div className="keyboard">
      {keys.map((row, idx) => (
        <div className="krow" key={idx}>
          {row.split("").map((k) => (
            <button className="kkey" key={k} onClick={() => onType(k)}>{k.toUpperCase()}</button>
          ))}
        </div>
      ))}
    </div>
  );
}
EOF

cat > "${ROOT_DIR}/frontend/src/styles.css" <<'EOF'
body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; padding: 1rem; }
.lobby { max-width: 600px; margin: 0 auto; display:flex; flex-direction:column; gap:0.5rem; }
.row { display:flex; gap:0.5rem; margin-top:0.5rem; }
.join { margin-top:0.5rem; display:flex; gap:0.5rem; }
.game-header { display:flex; gap:1rem; margin-bottom:1rem; }
.boards { display:flex; gap:1rem; flex-wrap:wrap; }
.player-board { border: 1px solid #ddd; padding:0.5rem; width:220px; }
.grid { display:flex; flex-direction:column; gap:4px; }
.row { display:flex; gap:4px; }
.cell { width:36px; height:36px; display:flex; align-items:center; justify-content:center; border:1px solid #ccc; font-weight:bold; text-transform:uppercase;}
.cell.correct { background:#6aaa64; color:white; }
.cell.present { background:#c9b458; color:white; }
.cell.absent { background:#787c7e; color:white; }
.guess-entry { margin-top:1rem; display:flex; gap:0.5rem; }
.keyboard { margin-top:1rem; }
.krow { display:flex; gap:4px; margin-bottom:6px; }
.kkey { padding:6px 8px; border-radius:4px; border:1px solid #ccc; background:#f3f3f3; cursor:pointer; }
.notifications { margin-top:1rem; max-width:600px; }
EOF

echo "All files written to ./${ROOT_DIR}/"
echo "Next steps:"
echo "1) cd ${ROOT_DIR}"
echo "2) (Optional) edit .env.example -> .env"
echo "3) docker-compose up --build"
echo "4) When MySQL is ready, load schema and sample words:"
echo "   docker exec -it <db-container-id> sh -c \"mysql -uroot -ppassword wordle < /docker-entrypoint-initdb.d/schema.sql\""
echo "   (or run locally: mysql -uroot -ppassword wordle < backend/schema.sql && mysql -uroot -ppassword wordle < backend/load_words.sql)"
echo "4) Open http://localhost:5173 (frontend) or http://localhost:5000 (backend)"
echo ""
echo "If you want, I can also produce a zip archive or push these files to a GitHub repo. Ready when you are."