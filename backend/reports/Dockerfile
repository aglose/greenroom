FROM node:22-slim

WORKDIR /app
COPY package.json server.mjs validate.mjs bigquery.mjs ratelimit.mjs ./

USER node
ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.mjs"]
