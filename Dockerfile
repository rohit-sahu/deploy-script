# Container-internal working directory. Rarely needs to change — override
# only if it conflicts with something else in your infra. Must be repeated
# as `ARG APP_DIR` in every stage below (build args don't cross FROM lines).
ARG APP_DIR=/opt/portfolio

# --- Dependencies stage ---
FROM node:20-alpine AS deps
ARG APP_DIR
WORKDIR $APP_DIR
COPY package.json package-lock.json ./
RUN npm ci

# --- Build stage ---
FROM node:20-alpine AS builder
ARG APP_DIR
WORKDIR $APP_DIR
COPY --from=deps $APP_DIR/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
# NEXT_PUBLIC_* vars are inlined into the JS bundle at build time, so this
# must be a build ARG/ENV here, not just a runtime env var on the container.
ARG NEXT_PUBLIC_SITE_URL
ENV NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL
RUN npm run build

# --- Production runtime stage ---
FROM node:20-alpine AS runner
ARG APP_DIR
WORKDIR $APP_DIR
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000

RUN addgroup --system --gid 1001 nodejs && adduser --system --uid 1001 nextjs

# `output: "standalone"` in next.config.ts produces a self-contained server
# bundle plus only the node_modules actually required at runtime.
COPY --from=builder --chown=nextjs:nodejs $APP_DIR/public ./public
COPY --from=builder --chown=nextjs:nodejs $APP_DIR/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs $APP_DIR/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# Docker Health Check to monitor container runtime status
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "server.js"]
