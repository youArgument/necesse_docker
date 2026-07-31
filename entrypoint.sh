#!/bin/bash
set -e

export HOME="/home/steam"
export CPU_MHZ=2000.000
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.steam/steam"

SERVER_DIR="/home/steam/necesse"
SAVE_DIR="/home/steam/saves"

echo "=== Обновление/проверка сервера Necesse (App ID: 1169370) ==="

# Запускаем steamcmd с явным объявлением частоты процессора и подавлением паники
CPU_MHZ=2000.000 steamcmd +@ShutdownOnFailedCommand 0 \
                         +@NoPromptForPassword 1 \
                         +force_install_dir "$SERVER_DIR" \
                         +login anonymous \
                         +app_update 1169370 validate \
                         +quit </dev/null || true

echo "=== Запуск сервера Necesse ==="
cd "$SERVER_DIR"

ARGS="-nogui -world ${WORLD_NAME:-MyWorld} -datadir $SAVE_DIR"

if [ -n "$PORT" ]; then
    ARGS="$ARGS -port $PORT"
fi

if [ -n "$SLOTS" ]; then
    ARGS="$ARGS -slots $SLOTS"
fi

if [ -n "$PASSWORD" ]; then
    ARGS="$ARGS -password $PASSWORD"
fi

if [ -f "./StartServer-nogui.sh" ]; then
    chmod +x ./StartServer-nogui.sh
    exec ./StartServer-nogui.sh $ARGS
else
    echo "Ошибка: StartServer-nogui.sh не найден в $SERVER_DIR!"
    exit 1
fi
