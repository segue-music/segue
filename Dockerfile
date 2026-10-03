FROM node:24-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
USER node
ENV SEGUE_LISTEN=0.0.0.0:8480
EXPOSE 8480
CMD ["node", "src/main.ts"]
