#!/usr/bin/env bash
# apply_sighup_reload.sh
#
# Переводит перезагрузку клиентов с отдельного SIGUSR1 на общий SIGHUP
# (вместе с TLS-хостами). Правки в endpoint/src/main.rs.
#
# Запуск из корня репозитория TrustTunnel:
#   cd ~/TrustTunnel
#   bash apply_sighup_reload.sh
#
# Требуется python3. Делает бэкап endpoint/src/main.rs.bak.

set -euo pipefail

ROOT="$(pwd)"
MAIN="$ROOT/endpoint/src/main.rs"

if [[ ! -f "$ROOT/Cargo.toml" || ! -d "$ROOT/endpoint/src" ]]; then
    echo "Запустите скрипт из корня репозитория TrustTunnel" >&2
    exit 1
fi

if [[ ! -f "$MAIN" ]]; then
    echo "Не найден файл: $MAIN" >&2
    exit 1
fi

# Проверяем, что правки с прошлого шага уже применены.
if ! grep -q 'fn reload_clients(settings_path: &str, core: &Core)' "$MAIN"; then
    echo "Ошибка: не найден хелпер reload_clients()." >&2
    echo "Сначала примените предыдущий патч (apply_reload_clients.sh)." >&2
    exit 1
fi

cp "$MAIN" "$MAIN.bak"
echo "Резервная копия: $MAIN.bak"

python3 - "$MAIN" <<'PYEOF'
import io, sys

path = sys.argv[1]

with io.open(path, "r", encoding="utf-8") as f:
    t = f.read()

def must_replace(text, needle, repl, desc):
    if needle not in text:
        raise SystemExit(
            "Не найден фрагмент для замены ({}):\n---\n{}\n---".format(desc, needle)
        )
    return text.replace(needle, repl, 1)

# ---------------------------------------------------------------------------
# 1. Заменить тело reload_tls_hosts_task и убрать reload_clients_task.
# ---------------------------------------------------------------------------
old_block = """    let reload_clients_task = {
        let settings_path = settings_path.clone();
        let core = core.clone();
        async move {
            let mut sigusr1 = signal::unix::signal(signal::unix::SignalKind::user_defined1())
                .expect("Couldn't start SIGUSR1 listener");

            loop {
                sigusr1.recv().await;
                info!("Reloading client credentials");
                match reload_clients(&settings_path, &core) {
                    Ok(()) => info!("Client credentials successfully reloaded"),
                    Err(e) => error!("Failed to reload client credentials: {}", e),
                }
            }
        }
    };

    let reload_tls_hosts_task = {
        let tls_hosts_settings_path = tls_hosts_settings_path.clone();
        async move {
            let mut sighup_listener = signal::unix::signal(signal::unix::SignalKind::hangup())
                .expect("Couldn't start SIGHUP listener");

            loop {
                sighup_listener.recv().await;
                info!("Reloading TLS hosts settings");

                let tls_hosts_settings: settings::TlsHostsSettings = toml::from_str(
                    &std::fs::read_to_string(&tls_hosts_settings_path)
                        .expect("Couldn't read the TLS hosts settings file"),
                )
                .expect("Couldn't parse the TLS hosts settings file");

                core.reload_tls_hosts_settings(tls_hosts_settings)
                    .expect("Couldn't apply new settings");
                info!("TLS hosts settings are successfully reloaded");
            }
        }
    };
"""

new_block = """    let reload_tls_hosts_task = {
        let tls_hosts_settings_path = tls_hosts_settings_path.clone();
        let settings_path = settings_path.clone();
        let core = core.clone();
        async move {
            let mut sighup_listener = signal::unix::signal(signal::unix::SignalKind::hangup())
                .expect("Couldn't start SIGHUP listener");

            loop {
                sighup_listener.recv().await;
                info!("SIGHUP received, reloading TLS hosts settings and client credentials");

                // 1) TLS hosts. Existing sessions stay up; new connections pick up
                //    the new certificates/SNIs.
                let tls_hosts_settings: settings::TlsHostsSettings = match std::fs::read_to_string(
                    &tls_hosts_settings_path,
                )
                .map_err(|e| {
                    io::Error::new(
                        e.kind(),
                        format!("Couldn't read the TLS hosts settings file: {}", e),
                    )
                })
                .and_then(|contents| {
                    toml::from_str::<settings::TlsHostsSettings>(&contents).map_err(|e| {
                        io::Error::new(
                            io::ErrorKind::InvalidData,
                            format!("Couldn't parse the TLS hosts settings file: {}", e),
                        )
                    })
                }) {
                    Ok(x) => x,
                    Err(e) => {
                        error!("Failed to reload TLS hosts settings: {}", e);
                        continue;
                    }
                };

                if let Err(e) = core.reload_tls_hosts_settings(tls_hosts_settings) {
                    error!("Failed to apply TLS hosts settings: {}", e);
                    continue;
                }
                info!("TLS hosts settings are successfully reloaded");

                // 2) Client credentials. Failures here are non-fatal: the previously
                //    loaded client list keeps working.
                match reload_clients(&settings_path, &core) {
                    Ok(()) => info!("Client credentials successfully reloaded"),
                    Err(e) => error!("Failed to reload client credentials: {}", e),
                }
            }
        }
    };
"""

t = must_replace(t, old_block, new_block, "reload_tls_hosts_task / reload_clients_task")

# ---------------------------------------------------------------------------
# 2. Убрать ветку reload_clients_task из tokio::select!.
# ---------------------------------------------------------------------------
old_branch = """            _ = reload_clients_task => {
                error!("Client credentials reload listener stopped unexpectedly");
                1
            },
"""

if old_branch in t:
    t = t.replace(old_branch, "", 1)
else:
    # Допускаем чуть другой формат — ищем по маркеру и вырезаем строку.
    marker = "_ = reload_clients_task"
    idx = t.find(marker)
    if idx != -1:
        # Найдём начало строки и конец блока (закрывающая `},`).
        line_start = t.rfind("\n", 0, idx) + 1
        close = t.find("},", idx)
        if close == -1:
            raise SystemExit("Не удалось удалить ветку reload_clients_task: не найден конец блока")
        end = t.find("\n", close) + 1
        t = t[:line_start] + t[end:]
    else:
        raise SystemExit(
            "Не найдена ветка `_ = reload_clients_task` в tokio::select! "
            "(возможно, патч уже применён)"
        )

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(t)

print("Правки в endpoint/src/main.rs применены.")
PYEOF

echo
echo "Проверка:"
grep -n "reload_clients_task" "$MAIN" && {
    echo "ВНИМАНИЕ: остались упоминания reload_clients_task — проверьте вручную." >&2
    exit 1
} || echo "  reload_clients_task больше не упоминается — ок"

grep -n "SIGHUP received, reloading" "$MAIN" >/dev/null \
    && echo "  SIGHUP-обработчик обновлён — ок" \
    || { echo "  Не найден новый обработчик SIGHUP" >&2; exit 1; }

grep -n "reload_clients(&settings_path, &core)" "$MAIN" >/dev/null \
    && echo "  reload_clients вызывается из SIGHUP-обработчика — ок" \
    || { echo "  reload_clients не вызывается" >&2; exit 1; }

echo
echo "Готово. Дальше:"
echo "  cargo build --workspace"
echo
echo "Откат: cp endpoint/src/main.rs.bak endpoint/src/main.rs"
