import sys
from pathlib import Path

import pandas as pd

from carregar_dados import (ARQUIVOS, carregar_tabela, conferir_contagens,
                            criar_engine, recriar_tabelas)

RAIZ = Path(__file__).resolve().parent.parent
PASTA_SQL = RAIZ / "sql"
PASTA_SAIDA = RAIZ / "saida"

SQLS_DO_PIPELINE = [
    "02_staging.sql",
    "03_casamento.sql",
    "04_validacoes.sql",
    "05_relatorio.sql",
    "06_conferencia.sql",
]

def rodar_carga(engine):
    print("Rodando carga de CSVs...")
    recriar_tabelas(engine)
    esperado = {
        tabela: carregar_tabela(engine, tabela, arquivo, sep)
        for tabela, (arquivo, sep) in ARQUIVOS.items()
    }
    conferir_contagens(engine, esperado)

def rodar_sqls(engine):
    for nome in SQLS_DO_PIPELINE:
        sql = (PASTA_SQL / nome).read_text(encoding="utf-8")
        try:
            with engine.begin() as conn:
                conn.exec_driver_sql(sql, execution_options={"no_parameters": True})
        except Exception as e:
            sys.exit(f"Erro ao rodar {nome}: {e}")
        print(f"Rodou {nome} com sucesso.")

def exportar_relatorio(engine):
    print("Exportação dos dados")
    PASTA_SAIDA.mkdir(exist_ok=True)
    consultas = {
        "divergencias": """
            SELECT * FROM divergencias
            ORDER BY provedor, categoria, chave
        """,
        "resumo": """
            SELECT provedor, categoria,
                   COUNT(*) AS qt_achados,
                   SUM(ABS(impacto_rs)) AS vl_impacto
            FROM divergencias
            GROUP BY provedor, categoria
            ORDER BY provedor, vl_impacto DESC
        """,
    }
    with pd.ExcelWriter(PASTA_SAIDA / "relatorio_conciliacao.xlsx") as excel:
        for aba, sql in consultas.items():
            df = pd.read_sql(sql, engine)
            df.to_csv(PASTA_SAIDA / f"{aba}.csv", index=False, encoding="utf-8-sig")
            df.to_excel(excel, sheet_name=aba, index=False)
    print(f"     relatório em {PASTA_SAIDA}")


def imprimir_resumo(engine):
    sql = """
        SELECT COUNT(*) FILTER (WHERE resultado = 'VP') AS vp,
               COUNT(*) FILTER (WHERE resultado = 'FP') AS fp,
               COUNT(*) FILTER (WHERE resultado = 'FN') AS fn
        FROM conc_comparacao
    """
    vp, fp, fn = pd.read_sql(sql, engine).iloc[0]
    precisao = 100 * vp / (vp + fp) if vp + fp else 0
    recall = 100 * vp / (vp + fn) if vp + fn else 0
    print(f"\n{vp + fp} achados | precisão {precisao:.1f}% | recall {recall:.1f}%")

def main():
    engine = criar_engine()
    rodar_carga(engine)
    rodar_sqls(engine)
    exportar_relatorio(engine)
    imprimir_resumo(engine)

if __name__ == "__main__":
    main()