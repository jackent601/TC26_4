# UI image (decision I6): official images only, no code of its own.
# Stage 1 builds the static files with Node; stage 2 serves them with Caddy,
# which also forwards /api/* to PostgREST (see Caddyfile).
FROM node:22.23-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM caddy:2.11-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/dist /srv
EXPOSE 8080
