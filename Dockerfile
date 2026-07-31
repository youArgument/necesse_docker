FROM steamcmd/steamcmd:debian-12

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/steam
ENV CPU_MHZ=2000.000

# Устанавливаем Java 17 для работы сервера Necesse
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-17-jre-headless \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Создаем пользователя steam и выставляем права
RUN useradd -m -s /bin/bash steam \
    && mkdir -p /home/steam/necesse /home/steam/saves \
    && chown -R steam:steam /home/steam

WORKDIR /home/steam

COPY --chown=steam:steam entrypoint.sh /home/steam/entrypoint.sh
RUN chmod +x /home/steam/entrypoint.sh

USER steam

ENV WORLD_NAME="MyWorld" \
    PORT="14159" \
    SLOTS="10" \
    PASSWORD=""

EXPOSE 14159/udp

ENTRYPOINT ["/home/steam/entrypoint.sh"]
