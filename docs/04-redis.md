# Redis

## Deployment Pattern

Redis runs as a single-replica Deployment in the `shared` namespace. It serves as an in-memory data store for SSE event fan-out, rate-limit counters, and Infisical's internal queue/cache.

### Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: shared
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          command: ["redis-server"]
          args:
            - "--maxmemory"
            - "200mb"
            - "--maxmemory-policy"
            - "allkeys-lru"
          ports:
            - containerPort: 6379
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: shared
spec:
  type: ClusterIP
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
```

### Key Configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| `maxmemory` | 200mb | Fits within the 256Mi container limit with headroom for Redis overhead |
| `maxmemory-policy` | allkeys-lru | Evicts least-recently-used keys when memory is full — safe for cache/rate-limit data |
| `appendonly` | no (default) | Persistence not needed — all data is ephemeral (rate counters, SSE channels) |

**Why no persistence:** All Redis data in this setup is ephemeral:
- Rate-limit counters: losing them means a brief window without rate limiting (acceptable)
- SSE channels: losing them means existing SSE connections drop and clients reconnect (acceptable)
- Data of record lives in PostgreSQL, not Redis

If you need durable Redis data (e.g., job queues), enable AOF: `--appendonly yes --appendfsync everysec`

## Key Prefix Conventions

All applications sharing this Redis instance use prefixed keys to avoid collisions:

| Prefix | Owner | Purpose | TTL |
|--------|-------|---------|-----|
| `rl:` | Backend | Rate-limit counters (`rl:ip:1.2.3.4`, `rl:user:123`) | 60-3600s |
| `sse:` | Backend | SSE pub/sub channels (`sse:notifications`, `sse:user:123`) | No TTL (pub/sub) |
| `bull:` | Infisical | BullMQ job queues | Varies |
| `cache:` | Infisical | Response caching | Varies |

**Convention:** New applications must pick a unique 2-4 character prefix and document it here. Never use unprefixed keys.

## Cross-Namespace Access

Apps in other namespaces access Redis via the fully-qualified DNS name:

```
redis://redis.shared.svc.cluster.local:6379
```

This is typically set as the `REDIS_URL` environment variable in the application's Infisical secrets.

Alternatively, create an ExternalName service in the app namespace:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: acme
spec:
  type: ExternalName
  externalName: redis.shared.svc.cluster.local
```

## Use Cases

### 1. SSE Fan-Out (Pub/Sub)

The backend uses Redis Pub/Sub to broadcast real-time events across all replicas:

```
Backend Pod A receives webhook → publishes to Redis channel "sse:notifications"
  → Redis fans out to ALL subscribers
  → Backend Pod B (subscriber) pushes event to its SSE clients
  → Backend Pod C (subscriber) pushes event to its SSE clients
  → ...
```

Without Redis, each backend pod only knows about its own SSE connections. A notification event on Pod A would never reach clients connected to Pod B. With 8 replicas, ~87% of events would be silently lost.

**Channels used:**
- `sse:notifications` — broadcast to all connected users
- `sse:user:<userId>` — targeted to a specific user's connections

### 2. Rate-Limit Counters (Shared Store)

Rate-limit counters must be shared across all backend replicas. Without a shared store, each replica maintains its own counter — an attacker spreading requests across replicas gets N× the actual limit.

```
Request arrives at Pod A → INCR rl:ip:1.2.3.4 → check against limit
Request arrives at Pod B → INCR rl:ip:1.2.3.4 → same counter, same limit
```

**Key patterns:**
```
rl:ip:<ip>                    # Per-IP rate limit
rl:user:<userId>              # Per-user rate limit
rl:phone:<phone>              # Per-phone (OTP pumping prevention)
rl:endpoint:<path>:<ip>       # Per-endpoint per-IP
```

### 3. Infisical Queue/Cache

Infisical's backend uses Redis internally for:
- BullMQ job queues (secret sync tasks, audit log processing)
- Response caching (API responses, template rendering)
- Session management

This is a separate Redis instance (`redis-master` in the `infisical` namespace), not the shared one. Infisical ships its own Redis via the Helm chart.

## Memory Management

### Monitoring

```bash
# Check memory usage
kubectl exec -n shared deploy/redis -- redis-cli INFO memory | grep -E "used_memory_human|maxmemory_human|mem_fragmentation"

# Check key count and distribution
kubectl exec -n shared deploy/redis -- redis-cli INFO keyspace

# Check connected clients
kubectl exec -n shared deploy/redis -- redis-cli INFO clients | grep connected_clients

# Check eviction stats
kubectl exec -n shared deploy/redis -- redis-cli INFO stats | grep evicted_keys
```

### Capacity Planning

Current allocation: 200MB maxmemory

| Consumer | Estimated Usage | Keys |
|----------|----------------|------|
| Rate-limit counters | ~5MB | Thousands of small counters, most with 60s TTL |
| SSE pub/sub | ~0MB | Pub/sub uses no memory for messages (fire-and-forget) |
| Infisical (separate instance) | N/A | Has its own Redis |

200MB is generous for the current workload. If `evicted_keys` starts climbing, bump `maxmemory` and the container memory limit proportionally.

### When to Scale

- **evicted_keys > 0 consistently:** Increase `maxmemory` — you're losing data you wanted to keep
- **connected_clients approaching hundreds:** Consider Redis Sentinel or a second instance
- **Latency spikes > 10ms (p99):** Check `slowlog` — usually a large key or blocking operation
- **Need durability:** Switch to a managed Redis (ElastiCache, Upstash) or enable AOF

## Failure Modes

| Scenario | Impact | Recovery |
|----------|--------|----------|
| Redis pod restart | SSE connections drop, rate counters reset | Clients auto-reconnect; counters rebuild in seconds |
| Redis OOM (eviction) | Oldest rate counters evicted | Brief window of weaker rate limiting; no data loss |
| Redis unreachable | SSE degrades to single-pod, rate limiting falls back to in-memory | App should handle Redis connection errors gracefully |

The application should treat Redis as an optimization, not a hard dependency. If Redis is down:
- SSE still works for clients connected to the same pod (no fan-out)
- Rate limiting falls back to per-process memory (weaker but functional)
- No application data is lost (PostgreSQL is the system of record)
