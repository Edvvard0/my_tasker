"""Builds the synthetic PDF statement ``tests/data/banks/vtb_synthetic.pdf`` (a ruled table).

Not run by the tests (the file is committed); rebuild with
``uv run python -m tests.banks_samples_gen`` (needs a Cyrillic TrueType font: DejaVu Sans).
Real statements from the customer replace this sample later.
"""

from pathlib import Path

from fpdf import FPDF

OUT = Path(__file__).resolve().parent / "data" / "banks" / "vtb_synthetic.pdf"
FONT = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")

HEADER = (
    "Дата операции",
    "Описание операции",
    "Сумма в валюте операции",
    "Валюта операции",
    "Сумма в валюте счёта",
    "Остаток",
)
ROWS = (
    ("03.10.2026", "Оплата Пятёрочка 1234 Москва", "-1 234,56", "RUB", "-1 234,56", "98 765,44"),
    ("04.10.2026", "Перевод с карты Т-Банк", "5 000,00", "RUB", "5 000,00", "103 765,44"),
    ("05.10.2026", "Оплата Steam", "-10,00", "USD", "-950,00", "102 815,44"),
    ("06.10.2026", "Оплата Лента", "-799,99", "RUB", "-799,99", "102 015,45"),
)


def build() -> None:
    pdf = FPDF()
    pdf.add_font("DejaVu", fname=str(FONT))
    pdf.set_font("DejaVu", size=10)
    pdf.add_page()
    pdf.cell(0, 8, "Выписка по счёту ВТБ (СИНТЕТИЧЕСКИЙ ОБРАЗЕЦ)", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 8, "за период с 01.10.2026 по 07.10.2026", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 8, "Номер карты: *5678", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)
    pdf.set_font("DejaVu", size=7)
    with pdf.table(col_widths=(18, 50, 28, 20, 28, 24), first_row_as_headings=False) as table:
        for line in (HEADER, *ROWS):
            row = table.row()
            for cell in line:
                row.cell(cell)
    pdf.ln(4)
    pdf.set_font("DejaVu", size=10)
    pdf.cell(0, 8, "Остаток на конец периода: 102 015,45 RUB", new_x="LMARGIN", new_y="NEXT")
    OUT.write_bytes(bytes(pdf.output()))


if __name__ == "__main__":
    build()
