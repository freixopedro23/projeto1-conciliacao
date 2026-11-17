"""Carga dos CSVs nas tabelas raw_* do PostgreSQL (etapa 0)."""
import os
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

RAIZ = Path(__file__).resolve().parent.parent
DADOS = RAIZ / "dados"
DDL = RAIZ / "sql" / "00_ddl_raw.sql"

# tabela -> (arquivo, separador)
ARQUIVOS = {
    "raw_transacoes_internas": ("transacoes_internas.csv", ","),
    "raw_extrato_pagaja": ("extrato_pagaja.csv", ";"),
    "raw_extrato_liquidapay": ("extrato_liquidapay.csv", ","),
    "raw_taxas_contratadas": ("taxas_contratadas.csv", ","),
}


def criar_engine():
    load_dotenv(RAIZ / ".env")
    url = (
        f"postgresql+psycopg2://{os.getenv('PG_USER')}:{os.getenv('PG_PASSWORD')}"
        f"@{os.getenv('PG_HOST', 'localhost')}:{os.getenv('PG_PORT', '5432')}"
        f"/{os.getenv('PG_DB')}"
    )
    return create_engine(url)


def recriar_tabelas(engine):
    """Roda o DDL: apaga e recria as tabelas raw, para a carga não duplicar."""
    with engine.begin() as conn:
        conn.exec_driver_sql(DDL.read_text(encoding="utf-8"))


def carregar_tabela(engine, tabela, arquivo, sep):
    df = pd.read_csv(DADOS / arquivo, sep=sep, dtype=str, keep_default_na=False)
    df.to_sql(tabela, engine, if_exists="append", index=False,
              method="multi", chunksize=1000)
    return len(df)


def conferir_contagens(engine, esperado):
    with engine.connect() as conn:
        for tabela, n_csv in esperado.items():
            n_banco = conn.execute(text(f"SELECT COUNT(*) FROM {tabela}")).scalar()
            status = "OK" if n_banco == n_csv else "DIVERGENTE"
            print(f"{tabela:<26} csv={n_csv:>5}  banco={n_banco:>5}  {status}")


def main():
    engine = criar_engine()
    recriar_tabelas(engine)
    esperado = {}
    for tabela, (arquivo, sep) in ARQUIVOS.items():
        esperado[tabela] = carregar_tabela(engine, tabela, arquivo, sep)
    conferir_contagens(engine, esperado)


if __name__ == "__main__":
    main()