# Enhanced Backend Dockerfile — Prisma + Express + TypeScript
#
# Features:
#   - Multi-stage build (builder → runtime)
#   - Prisma client generation in builder
#   - Prisma schema + migrations copied for in-cluster migrate/seed
#   - NODE_ENV=production pinned in runtime (fail-closed)
#   - Health check built in
#   - Optional: scripts/ directory for backfill/utility scripts
#
# Build args:
#   None required — VITE_API_BASE_URL is frontend-only
#
# Ports:
#   5000 (default Express port — change if needed)

# ── Builder ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

# Install dependencies first (layer cache)
COPY package*.json ./
RUN npm ci

# Copy source and build
COPY . .
RUN npx prisma generate \
 && npm run build

# ── Runtime ────────────────────────────────────────────────────────────
FROM node:22-alpine

# Fail-closed: if the env var is unset, the app still runs in production mode.
# The Deployment manifest also sets NODE_ENV=production explicitly.
ENV NODE_ENV=production
WORKDIR /app

# Install production dependencies only
COPY --from=builder /app/package*.json ./
RUN npm ci --omit=dev \
 && npm cache clean --force

# Prisma client (generated binaries)
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma ./node_modules/@prisma

# Prisma schema + migrations (needed for in-cluster prisma migrate deploy)
COPY --from=builder /app/prisma ./prisma

# Compiled application
COPY --from=builder /app/dist ./dist

# Optional: utility scripts that run in-cluster (seed, backfill, etc.)
# Uncomment if your project has a scripts/ directory:
# COPY --from=builder /app/scripts ./scripts

# Optional: model files for OCR/ML features
# Uncomment if your project downloads tessdata or other models:
# COPY --from=builder /app/.tessdata ./.tessdata

# Health check — the backend should expose /api/health
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:5000/api/health || exit 1

EXPOSE 5000

CMD ["node", "dist/server.js"]
