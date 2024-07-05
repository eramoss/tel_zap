FROM elixir:1.16.1-alpine

COPY . .
CMD [ "mix", "app.start" ]