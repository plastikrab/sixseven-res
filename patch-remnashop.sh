#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  patch-remnashop.sh
#  Патч совместимости Remnashop 0.7.3 с Remnawave v2
# ─────────────────────────────────────────────────────────────────
#
#  Проблема 1: после обновления Remnawave до v2 бот падает с ошибкой
#  ValidationError при открытии раздела Remnawave в админке.
#  Причина: Remnawave v2 изменил структуру API-ответов.
#
#  Проблема 2: Remnawave v2 добавил стратегию сброса трафика
#  MONTH_ROLLING («ежемесячно по дате создания»). Бот её не знает —
#  падает с ValidationError при синхронизации пользователей,
#  у которых выставлена эта стратегия.
#
#  Что делает скрипт:
#    1. remnapy/models/system.py   — physicalCores, active, available
#                                    становятся Optional (не обязательными)
#    2. remnapy/models/system.py   — добавляет поле cores: Optional[int]
#                                    в модель CPU (новое поле Remnawave v2)
#    3. remnapy/models/nodes.py    — xrayUptime меняется на тип Any
#    4. remnapy/models/webhook.py  — xrayUptime меняется на тип Any
#    5. routers/.../getters.py     — добавляет fallback:
#                                    physical_cores → cores
#                                    memory.active  → memory.used
#    6. remnapy/enums/users.py     — добавляет MONTH_ROLLING в enum
#                                    TrafficLimitStrategy
#    7. PostgreSQL                 — добавляет MONTH_ROLLING в тип
#                                    plan_traffic_limit_strategy
#    8. assets/translations        — добавляет перевод MONTH_ROLLING
#                                    в utils.ftl и messages.ftl
#    9. Перезапускает все контейнеры remnashop
#
#  ⚠️  Патч живёт внутри контейнера и пропадёт при пересборке образа.
#      Когда автор Remnashop выпустит обновление с фиксом — патч
#      больше не понадобится.
#
#  Использование:
#    chmod +x patch-remnashop.sh && ./patch-remnashop.sh
# ─────────────────────────────────────────────────────────────────

set -e

CONTAINER="remnashop"
DB_CONTAINER="remnashop-db"
REMNAPY="/opt/remnashop/.venv/lib/python3.12/site-packages/remnapy/models"
REMNAPY_ENUMS="/opt/remnashop/.venv/lib/python3.12/site-packages/remnapy/enums"
GETTERS="/opt/remnashop/src/telegram/routers/dashboard/remnawave/getters.py"
ASSETS="/opt/remnashop/assets/translations/ru"

echo "🔧 Патч Remnashop 0.7.3 для совместимости с Remnawave v2"
echo ""

# ──────────────────────────────────────────────────────────────────
#  Блок 1: фиксы структуры API (были в оригинальном патче)
# ──────────────────────────────────────────────────────────────────

echo "[1/9] system.py — physicalCores, active, available → Optional..."
docker exec "$CONTAINER" sed -i \
  's/physical_cores: int = Field(alias="physicalCores")/physical_cores: Optional[int] = Field(None, alias="physicalCores")/' \
  "$REMNAPY/system.py"
docker exec "$CONTAINER" sed -i \
  's/    active: int/    active: Optional[int] = None/' \
  "$REMNAPY/system.py"
docker exec "$CONTAINER" sed -i \
  's/    available: int/    available: Optional[int] = None/' \
  "$REMNAPY/system.py"

echo "[2/9] system.py — добавление поля cores в модель CPU..."
docker exec "$CONTAINER" sed -i \
  '/physical_cores: Optional\[int\] = Field(None, alias="physicalCores")/a\    cores: Optional[int] = None' \
  "$REMNAPY/system.py"

echo "[3/9] nodes.py — xrayUptime: str → Any..."
docker exec "$CONTAINER" sed -i \
  's/^from typing import Annotated, List, Literal, Optional, Union/from typing import Annotated, Any, List, Literal, Optional, Union/' \
  "$REMNAPY/nodes.py"
docker exec "$CONTAINER" sed -i \
  's/xray_uptime: str = Field(alias="xrayUptime")/xray_uptime: Any = Field(None, alias="xrayUptime")/' \
  "$REMNAPY/nodes.py"

echo "[4/9] webhook.py — xrayUptime: str → Any..."
docker exec "$CONTAINER" sed -i \
  's/^from typing import List, Literal, Optional, Union/from typing import Any, List, Literal, Optional, Union/' \
  "$REMNAPY/webhook.py"
docker exec "$CONTAINER" sed -i \
  's/xray_uptime: str$/xray_uptime: Any = None/' \
  "$REMNAPY/webhook.py"

echo "[5/9] getters.py — fallback для cpu_cores и memory.active..."
docker exec "$CONTAINER" sed -i \
  's/"cpu_cores": result.cpu.physical_cores,/"cpu_cores": result.cpu.physical_cores or result.cpu.cores,/' \
  "$GETTERS"
docker exec "$CONTAINER" sed -i \
  's/i18n_format_bytes_to_unit(result.memory.active),/i18n_format_bytes_to_unit(result.memory.active or result.memory.used),/' \
  "$GETTERS"
docker exec "$CONTAINER" sed -i \
  's/part=result.memory.active,/part=result.memory.active or result.memory.used,/' \
  "$GETTERS"

# ──────────────────────────────────────────────────────────────────
#  Блок 2: поддержка стратегии MONTH_ROLLING
# ──────────────────────────────────────────────────────────────────

echo "[6/9] remnapy/enums/users.py — добавление MONTH_ROLLING в TrafficLimitStrategy..."
# Патч применяется ко ВСЕМ трём контейнерам: у каждого своя копия venv в образе.
# Краш в taskiq-worker происходит именно из-за его непропатченной копии.
patch_enum() {
  local C="$1"
  echo "  → $C"
  docker exec -i "$C" python3 - << 'PYEOF'
import re, glob, os

path = "/opt/remnashop/.venv/lib/python3.12/site-packages/remnapy/enums/users.py"

with open(path) as f:
    content = f.read()

if "MONTH_ROLLING" in content:
    print("    ~ MONTH_ROLLING уже существует, пропускаем")
else:
    new_content = re.sub(
        r"([ \t]*MONTH\s*=\s*['\"]MONTH['\"][^\n]*\n)",
        r'\1    MONTH_ROLLING = "MONTH_ROLLING"\n',
        content,
        count=1
    )
    if new_content == content:
        print("    ⚠️  Паттерн MONTH не найден! Содержимое users.py:")
        print(content)
    else:
        with open(path, "w") as f:
            f.write(new_content)
        print("    ✓ MONTH_ROLLING добавлен в TrafficLimitStrategy")

cache_dir = os.path.dirname(path).replace("enums", "enums/__pycache__")
for pyc in glob.glob(f"{cache_dir}/*.pyc"):
    os.remove(pyc)
    print(f"    ✓ Удалён кэш: {pyc}")
PYEOF
}

patch_enum remnashop
patch_enum remnashop-taskiq-worker
patch_enum remnashop-taskiq-scheduler

echo "[7/9] PostgreSQL — добавление MONTH_ROLLING в тип plan_traffic_limit_strategy..."
docker exec "$DB_CONTAINER" sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ALTER TYPE plan_traffic_limit_strategy ADD VALUE IF NOT EXISTS '"'"'MONTH_ROLLING'"'"';"'

echo "[8/9] FTL-переводы — добавление метки MONTH_ROLLING..."
docker exec -i "$CONTAINER" python3 - << 'PYEOF'
import os

LABEL = "    [MONTH_ROLLING] Ежемесячно (по дате создания)"
MONTH_LINE = "    [MONTH] Каждый месяц"

files = [
    "/opt/remnashop/assets/translations/ru/utils.ftl",
    "/opt/remnashop/assets/translations/ru/messages.ftl",
]

for path in files:
    with open(path) as f:
        content = f.read()

    if "MONTH_ROLLING" in content:
        print(f"  ~ {os.path.basename(path)}: MONTH_ROLLING уже есть, пропускаем")
        continue

    # Вставляем строку MONTH_ROLLING сразу после каждой строки [MONTH] Каждый месяц
    new_content = content.replace(
        MONTH_LINE,
        MONTH_LINE + "\n" + LABEL
    )

    if new_content == content:
        print(f"  ⚠️  {os.path.basename(path)}: паттерн не найден!")
    else:
        with open(path, "w") as f:
            f.write(new_content)
        count = content.count(MONTH_LINE)
        print(f"  ✓ {os.path.basename(path)}: добавлено {count} вхождение(ий)")
PYEOF

echo "[9/9] Перезапуск контейнеров..."
# Перезапускаем все три: основной бот и оба воркера
for C in remnashop-taskiq-scheduler remnashop-taskiq-worker remnashop; do
  echo "  → $C"
  docker restart "$C"
done

echo ""
echo "✅ Готово! Патч применён, все контейнеры перезапущены."
echo ""
echo "   Добавленная стратегия:"
echo "   MONTH_ROLLING — «Ежемесячно (по дате создания)»"
echo "   Отображается в боте как 5-й вариант при выборе сброса трафика."