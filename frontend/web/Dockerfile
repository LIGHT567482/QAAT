# QAAT web — Next.js staff dashboards (admin / QA / KIU-admin).
FROM node:20-alpine AS deps
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9 --activate
COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile || pnpm install

FROM node:20-alpine AS build
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9 --activate
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ARG NEXT_PUBLIC_API_URL=http://localhost:8080
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
RUN pnpm build

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
RUN corepack enable && corepack prepare pnpm@9 --activate
COPY --from=build /app/package.json /app/pnpm-lock.yaml* ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/.next ./.next
COPY --from=build /app/public ./public
COPY --from=build /app/next.config.mjs ./
EXPOSE 3000
CMD ["pnpm", "start"]
