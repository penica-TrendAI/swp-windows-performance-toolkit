"""Render the kit's Markdown handbook to Word and optionally export its PDFs."""
import argparse
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from docx import Document
from docx.enum.style import WD_STYLE_TYPE
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.opc.constants import RELATIONSHIP_TYPE as RT
from docx.shared import Cm, Pt, RGBColor

ACCENT = "235A63"
INK = "18282B"


def element(name, **attributes):
    el = OxmlElement("w:" + name)
    for key, value in attributes.items():
        el.set(qn("w:" + key), str(value))
    return el


def hyperlink(p, caption, url):
    link = element("hyperlink")
    link.set(qn("r:id"), p.part.relate_to(url, RT.HYPERLINK, is_external=True))
    run = element("r")
    props = element("rPr")
    props.append(element("color", val=ACCENT))
    props.append(element("u", val="single"))
    run.append(props)
    text = element("t")
    text.text = caption
    run.append(text)
    link.append(run)
    p._p.append(link)


def inline(p, source):
    pattern = r"(\*\*.+?\*\*|\x60[^\x60]+\x60|\[[^\]]+\]\([^)]+\))"
    for piece in re.split(pattern, source):
        if piece.startswith("**") and piece.endswith("**"):
            p.add_run(piece[2:-2]).bold = True
        elif piece.startswith(chr(96)) and piece.endswith(chr(96)):
            r = p.add_run(piece[1:-1])
            r.font.color.rgb = RGBColor.from_string(ACCENT)
        elif re.fullmatch(r"\[[^\]]+\]\([^)]+\)", piece):
            label, url = piece[1:-1].split("](", 1)
            hyperlink(p, label, url)
        else:
            p.add_run(piece)


def style(doc, name, size, color=INK, font="Calibri", after=5, leading=1.15):
    styles = doc.styles
    s = styles[name] if name in styles else styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
    s.font.name = font
    s.font.size = Pt(size)
    s.font.color.rgb = RGBColor.from_string(color)
    fmt = s.paragraph_format
    fmt.space_before = Pt(0)
    fmt.space_after = Pt(after)
    fmt.line_spacing = leading
    return s


def table(doc, lines):
    rows = [[v.strip() for v in line.strip().strip("|").split("|")] for line in lines]
    rows = [rows[0]] + rows[2:]
    widths = (5.5, 11.9)
    t = doc.add_table(rows=0, cols=2)
    t.autofit = False
    for column, width in zip(t.columns, widths):
        column.width = Cm(width)
    for i, values in enumerate(rows):
        row = t.add_row()
        row._tr.get_or_add_trPr().append(element("cantSplit"))
        if i == 0:
            row._tr.get_or_add_trPr().append(element("tblHeader", val="true"))
        if len(values) != 2:
            raise ValueError(f"Expected a two-column Markdown table: {values}")
        for j, (cell, value) in enumerate(zip(row.cells, values)):
            cell.width = Cm(widths[j])
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            if not i or i % 2:
                cell._tc.get_or_add_tcPr().append(element("shd", fill="DCEBEC" if not i else "F3F6F6"))
            p = cell.paragraphs[0]
            p.style = "Guide Table"
            inline(p, value)
            if not i:
                for run in p.runs:
                    run.bold = True
    return t


def render(source, destination):
    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Cm(21), Cm(29.7)
    sec.left_margin, sec.right_margin = Cm(1.8), Cm(1.8)
    sec.top_margin, sec.bottom_margin = Cm(1.95), Cm(1.7)
    sec.header_distance, sec.footer_distance = Cm(0.9), Cm(0.8)
    style(doc, "Normal", 12, after=8, leading=1.17)
    title = style(doc, "Title", 27, color="111111", after=10)
    title.font.bold = True
    h = style(doc, "Heading 1", 22, color="111111", after=10)
    h.font.bold = True
    h.paragraph_format.keep_with_next = True
    for s in (title, h):
        pr = s.element.get_or_add_pPr()
        border = pr.find(qn("w:pBdr"))
        if border is not None:
            pr.remove(border)
    style(doc, "Guide Table", 11.0, after=4.1, leading=1.1)
    style(doc, "Guide Code", 9.2, font="Liberation Mono", after=8, leading=1.17)
    style(doc, "Running Text", 9, color="465B5F", after=0)
    header = sec.header.paragraphs[0]
    header.style = "Running Text"
    header.add_run("SWP-Perf   /   Windows sign-in performance collection")
    footer = sec.footer.paragraphs[0]
    footer.style = "Running Text"
    footer.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    footer.add_run("26 November 2026     ·     ")
    footer._p.append(element("fldSimple", instr="PAGE"))
    meta = doc.core_properties
    meta.title = "Windows sign-in performance collection"
    meta.subject = "SWP-Perf user and maintenance handbook"
    meta.author = "SWP performance collection"
    lines = source.read_text(encoding="utf-8").splitlines()
    i = 0
    count = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.strip():
            continue
        if line.startswith("# "):
            doc.add_paragraph(line[2:], "Title")
        elif line.startswith("## "):
            count += 1
            p = doc.add_paragraph(line[3:], "Heading 1")
            if count > 1:
                p.paragraph_format.page_break_before = True
        elif line.startswith(chr(96) * 3):
            code = []
            while i < len(lines) and not lines[i].startswith(chr(96) * 3):
                code.append(lines[i])
                i += 1
            if i == len(lines):
                raise ValueError("Unclosed code fence")
            i += 1
            p = doc.add_paragraph(style="Guide Code")
            p.paragraph_format.keep_together = True
            p.paragraph_format.left_indent = Cm(0.18)
            p.paragraph_format.right_indent = Cm(0.12)
            p._p.get_or_add_pPr().append(element("shd", fill="F1F5F5"))
            p.add_run("\n".join(code))
        elif line.startswith("|"):
            group = [line]
            while i < len(lines) and lines[i].startswith("|"):
                group.append(lines[i])
                i += 1
            table(doc, group)
        else:
            p = doc.add_paragraph()
            if re.match(r"^\d+\.\s", line):
                p.paragraph_format.left_indent = Cm(0.52)
                p.paragraph_format.first_line_indent = Cm(-0.52)
            inline(p, line)
    doc.save(destination)
    return count


def export_pdfs(document, total, soffice):
    from pypdf import PdfReader, PdfWriter
    with tempfile.TemporaryDirectory() as folder:
        profile = (Path(folder) / "profile").resolve().as_uri()
        subprocess.run([soffice, "-env:UserInstallation=" + profile, "--headless",
                        "--convert-to", "pdf", "--outdir", folder, str(document)], check=True)
        pdf = Path(folder) / document.with_suffix(".pdf").name
        reader = PdfReader(pdf)
        if len(reader.pages) != total or "Participant instructions" not in reader.pages[1].extract_text():
            raise ValueError("Review pagination before generating the one-page participant sheet")
        handouts = {
            "Participant-sheet.pdf": (1, "Participant instructions"),
            "Administrator-participant.pdf": (5, "Test your own administrator account"),
        }
        for name, (index, heading) in handouts.items():
            if heading not in " ".join(reader.pages[index].extract_text().split()):
                raise ValueError(f"Review the source page for {name}")
            with (document.parent / name).open("wb") as stream:
                writer = PdfWriter()
                writer.add_page(reader.pages[index])
                writer.write(stream)
        shutil.copyfile(pdf, document.with_suffix(".pdf"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pdf", action="store_true")
    parser.add_argument("--soffice", default="soffice")
    args = parser.parse_args()
    docs = Path(__file__).resolve().parents[1] / "Documentation"
    output = docs / "SWP-Perf-Handbook.docx"
    source = docs / "Handbook.md"
    pages = render(source, output)
    heading = "## Test your own administrator account"
    text = source.read_text(encoding="utf-8")
    solo = text.split(heading + "\n", 1)[1].split("\n## ", 1)[0]
    (docs / "Administrator-participant.md").write_text("# " + heading[3:] + "\n" + solo.rstrip() + "\n", encoding="utf-8")
    if args.pdf:
        export_pdfs(output, pages, args.soffice)
    print(output)
