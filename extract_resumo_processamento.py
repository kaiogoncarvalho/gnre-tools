import re
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
LOG_DIR = ROOT / "resources" / "log" / "container"

# Pega o campo message do dict python: {'message': '...'
MSG_FIELD = re.compile(r"\{'message':\s*'(?P<msg>.*?)'\s*,\s*'context':", re.DOTALL)

# Dentro do message:
# [MS][01/12/2025 - 31/12/2025][30/12/2025][INFO] - ... - Processamento finalizado. Processado com sucesso: 11, Processado com erro: 0, Valor Total: 2617.41
FINALIZED = re.compile(
    r"\[MS]\[[^]]+]\[(?P<data>\d{2}/\d{2}/\d{4})]\[INFO].*?Processamento finalizado\.\s*"
    r"Processado com sucesso:\s*(?P<ok>\d+),\s*Processado com erro:\s*(?P<err>\d+),\s*Valor Total:\s*(?P<valor>[-+]?\d+(?:\.\d+)?)"
)


def format_brl(value: float) -> str:
    s = f"{value:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return f"R$ {s}"


def extract_matches(text: str):
    # Extrai cada ocorrência do campo message de forma simples.
    for m in MSG_FIELD.finditer(text):
        msg = m.group("msg")
        # dict python usa \' para aspas simples. desfaz o escape.
        msg = msg.replace("\\'", "'")
        fm = FINALIZED.search(msg)
        if fm:
            yield (
                fm.group("data"),
                int(fm.group("ok")),
                int(fm.group("err")),
                float(fm.group("valor")),
            )


def parse_date_br(s: str) -> datetime:
    return datetime.strptime(s, "%d/%m/%Y")


def main() -> int:
    if not LOG_DIR.exists():
        print(f"Pasta não encontrada: {LOG_DIR}")
        return 2

    rows = []
    for path in sorted(LOG_DIR.rglob("*.container.log")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            text = path.read_text(encoding="latin-1", errors="replace")

        for data, ok, err, valor in extract_matches(text):
            rows.append((data, ok, err, valor))

    if not rows:
        print("Nenhum arquivo com 'Processamento finalizado' encontrado.")
        return 0

    rows.sort(key=lambda r: parse_date_br(r[0]))

    sep = "----------------------------------------"
    for i, (data, ok, err, valor) in enumerate(rows):
        print(f"Data: {data}")
        print(f"Guias: {ok}")
        print(f"Erros: {err}")
        print(f"Valor Total: {format_brl(valor)}")
        print(sep)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
