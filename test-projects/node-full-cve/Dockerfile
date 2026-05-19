FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY dist/ ./dist/
USER node
CMD ["node", "dist/index.js"]
