# Enhanced Frontend Dockerfile — Vite React + Nginx
#
# Features:
#   - Multi-stage build (node builder → nginx runtime)
#   - VITE_API_BASE_URL baked at build time (default: /api)
#   - Nginx with security headers, gzip, SPA routing, API proxy
#   - Static assets cached aggressively (Vite uses content hashes)
#
# Build args:
#   VITE_API_BASE_URL — API base path, baked into the JS bundle (default: /api)
#
# Ports:
#   80 (nginx serves static files + proxies /api/)

# ── Builder ────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

# The API URL is baked into the Vite bundle at build time.
# In production, the frontend and backend share a domain — /api is relative.
ARG VITE_API_BASE_URL=/api
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}

# Install dependencies first (layer cache)
COPY package*.json ./
RUN npm ci

# Copy source and build
COPY . .
RUN npm run build

# ── Runtime ────────────────────────────────────────────────────────────
FROM nginx:1.27-alpine

# Remove default nginx config
RUN rm -f /etc/nginx/conf.d/default.conf

# Copy built assets
COPY --from=builder /app/dist /usr/share/nginx/html

# Copy custom nginx config (must be in the same directory as this Dockerfile)
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
