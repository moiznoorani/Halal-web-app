#!/bin/bash
set -e

echo "========================================="
echo "  Halal Restaurant Finder - Codespaces"
echo "========================================="

cd /workspace

# ── 1. Install dependencies ───────────────────────────────────────────────
echo ""
echo "📦 Installing server dependencies..."
cd server && npm install
cd ..

echo "📦 Installing client dependencies..."
cd client && npm install --legacy-peer-deps
cd ..

echo "📦 Installing root dependencies (scraper)..."
npm install

# ── 2. Wait for PostgreSQL to be ready ───────────────────────────────────
echo ""
echo "⏳ Waiting for PostgreSQL..."
until pg_isready -h localhost -U postgres -q; do
  sleep 1
done
echo "✅ PostgreSQL is ready."

# ── 3. Run database migrations ────────────────────────────────────────────
echo ""
echo "🗄️  Running database migrations..."
PGPASSWORD=password psql -h localhost -U postgres -d yelp -f server/DB/db.sql \
  && echo "✅ Migration complete." \
  || echo "⚠️  Migration had warnings (may already be applied — this is OK)."

# ── 4. Seed existing restaurant data if DB is empty ──────────────────────
echo ""
ROW_COUNT=$(PGPASSWORD=password psql -h localhost -U postgres -d yelp -tAc "SELECT COUNT(*) FROM restaurants;" 2>/dev/null || echo "0")
if [ "$ROW_COUNT" -eq "0" ] && [ -f "restaurants.json" ]; then
  echo "🌱 Seeding restaurants from restaurants.json..."
  cd scrape_data
  node to_db.js ../restaurants.json
  cd ..
  echo "✅ Seed complete."
else
  echo "ℹ️  Database already has $ROW_COUNT restaurants — skipping seed."
fi

# ── 5. Batch-calculate halal scores ──────────────────────────────────────
echo ""
echo "⚡ Calculating halal scores (background)..."
# Start server briefly to run batch recalculate
(cd server && node -e "
  require('dotenv').config();
  const db = require('./db');
  const { updateRestaurantHalalScore } = require('./services/halalScore');
  (async () => {
    const res = await db.query('SELECT id FROM restaurants');
    for (const row of res.rows) {
      await updateRestaurantHalalScore(db, row.id);
    }
    console.log('Scored', res.rows.length, 'restaurants.');
    process.exit(0);
  })();
") && echo "✅ Halal scores calculated." || echo "⚠️  Score calculation skipped (no data yet)."

# ── 6. Start both servers via tmux (or background processes) ─────────────
echo ""
echo "🚀 Starting servers..."

# Use tmux if available, otherwise nohup background processes
if command -v tmux &> /dev/null; then
  tmux new-session -d -s halal -x 220 -y 50
  tmux send-keys -t halal "cd /workspace/server && npm start" C-m
  tmux split-window -h -t halal
  tmux send-keys -t halal "cd /workspace/client && npm start" C-m
  echo "✅ Servers started in tmux session 'halal'."
  echo "   Attach with: tmux attach -t halal"
else
  cd /workspace/server && npm start &
  cd /workspace/client && BROWSER=none npm start &
  echo "✅ Servers started in background."
fi

echo ""
echo "========================================="
echo "  ✅ Setup complete!"
echo ""
echo "  Frontend : http://localhost:3000"
echo "  API      : http://localhost:3001/api/v1/restaurants"
echo ""
echo "  To run the scraper (needs SERPAPI_KEY in server/.env):"
echo "    cd scrape_data && node main.js --cities=chicago"
echo "========================================="
