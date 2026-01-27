# --- Debug no Docker (debugpy ou PyCharm pydevd) ---
# Modos suportados:
# 1) DEBUGPY=1: o CONTAINER abre a porta e você faz attach via debugpy.
# 2) PYCHARM_DEBUG=1: o PYCHARM abre o "Python Debug Server" e o container conecta nele via pydevd_pycharm.
try:
    import os

    # --- Plano B: PyCharm Python Debug Server (pydevd_pycharm) ---
    # Use quando sua versão do PyCharm NÃO tem "Attach to debugpy".
    if os.getenv("PYCHARM_DEBUG") in {"1", "true", "True"}:
        import pydevd_pycharm

        host = os.getenv("PYCHARM_DEBUG_HOST", "host.docker.internal")
        port = int(os.getenv("PYCHARM_DEBUG_PORT", "5678"))
        suspend = os.getenv("PYCHARM_DEBUG_SUSPEND", "1") in {"1", "true", "True"}

        print(f"[pycharm] Conectando no Debug Server em {host}:{port} (suspend={suspend})")
        # Nota: assinaturas variam por versão; mantemos argumentos mínimos e compatíveis.
        pydevd_pycharm.settrace(host, port=port, suspend=suspend)

except Exception:
    # Nunca derruba o robô por causa de debug
    pass
# --- fim debug ---

import main

