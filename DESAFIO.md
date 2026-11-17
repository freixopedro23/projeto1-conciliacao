# Projeto 1 – Conciliação de Pagamentos

## O cenário

Você é analista de dados de uma plataforma online fictícia que recebe depósitos e paga saques por dois provedores de pagamento, também fictícios: **PagaJá** e **LiquidaPay**. Fechou outubro de 2026 e o financeiro precisa saber se o que o sistema interno registrou bate com o que os provedores liquidaram.

Sua entrega é um **relatório de divergências**: o que não bate, por quê, quanto vale em reais e quem precisa agir (o provedor ou o time interno).

Os dados têm problemas plantados de propósito. Há **pelo menos 7 tipos de divergência real** e também **algumas armadilhas que parecem erro mas não são**. Parte do desafio é separar uma coisa da outra.

## Os arquivos

| Arquivo | O que é |
| --- | --- |
| `dados/transacoes_internas.csv` | Base interna: 6.000 transações de outubro |
| `dados/extrato_pagaja.csv` | Extrato de liquidação da PagaJá |
| `dados/extrato_liquidapay.csv` | Extrato de liquidação da LiquidaPay |
| `dados/taxas_contratadas.csv` | Contrato com cada provedor: taxa e prazo |
| `dados/conciliacao.db` | Banco SQLite de referência, com os 4 arquivos já carregados em tabelas `raw_*`. **Não é a base de trabalho:** você monta o seu banco na etapa 0 e usa este só para conferir a sua carga |
| `gabarito/gabarito_divergencias.csv` | As respostas. **Não abra antes da etapa 6.** |
| `src/gerar_dados.py` | O gerador. `python src/gerar_dados.py --seed 7` cria uma massa nova, com outros erros |

**O que você escreve** (todo o código daqui para frente é seu):

| Arquivo | O que é |
| --- | --- |
| `sql/00_ddl_raw.sql` | Criação das tabelas `raw_*` |
| `src/carregar_dados.py` | Carga dos CSVs no banco |
| `sql/01_perfil.sql` a `sql/05_relatorio.sql` | Uma etapa por arquivo |
| `src/pipeline.py` | Roda tudo em ordem e exporta o relatório (etapa 7) |

Arquitetura do pipeline: **CSV → raw (carga, sem transformação) → staging (padronização) → conciliação → relatório**.

## Regras do negócio

**Base interna**
- `status`: APROVADA, RECUSADA, PENDENTE ou ESTORNADA. Só APROVADA e ESTORNADA movimentam dinheiro no provedor.
- `criado_em` e `atualizado_em` estão no horário de Brasília.
- Saques são sempre PIX. Cartão é só para depósito.

**Contrato** (`taxas_contratadas.csv`)
- Taxa cobrada = `valor × taxa_pct / 100 + taxa_fixa`, arredondada para 2 casas. Tolerância de R$ 0,01 para arredondamento.
- Prazo de liquidação em dias corridos, contado a partir da data da transação no horário de Brasília.
- Os extratos trazem só as liquidações até 31/10/2026.

**Sinal do valor líquido** (efeito no caixa da plataforma)
- Depósito: `+ bruto − taxa`
- Saque: `− (bruto + taxa)`
- Estorno: `− bruto` (a taxa não é devolvida)

**Layout da PagaJá**
- Separador `;`, decimal com vírgula, datas `dd/mm/aaaa`.
- `pedido` é o nosso `id_transacao`, mas sem hífen e em minúsculas (`tx000123`).
- `operacao`: C = crédito (depósito), D = débito (saque), E = estorno.

**Layout da LiquidaPay**
- CSV padrão, em inglês.
- `merchant_reference` é o nosso `id_transacao`.
- `transaction_datetime_utc` está em **UTC**. `settlement_date` já está em data local.
- `entry_type`: SALE (depósito), PAYOUT (saque), REFUND (estorno).

## Etapas

A análise é toda em SQL. Python entra na carga (etapa 0) e no pipeline (etapa 7). Salve cada etapa em um arquivo na pasta `sql/` e faça um commit no Git ao fim de cada uma.

### 0. Preparação e montagem do banco
**Repositório**
- Crie o repositório Git e suba para o GitHub.
- Crie um `.gitignore` com `__pycache__/`, `*.db` e arquivos de ambiente (`.env`, `.venv/`). O banco passa a ser gerado pelo script, então não vai para o repositório.

**Banco**
- Escolha o banco. PostgreSQL é o mais valorizado e o recomendado. SQLite é a alternativa se a instalação travar.
- Escreva o `sql/00_ddl_raw.sql`: uma tabela `raw_*` por arquivo, **com todas as colunas em texto**, espelhando os nomes das colunas do CSV.

**Carga (`src/carregar_dados.py`)**
- Leia os 4 CSVs com `pd.read_csv(..., dtype=str)`, para nada ser convertido na leitura.
- PagaJá: use `sep=";"`. **Não** use `decimal=","`: converter é trabalho da etapa 2.
- Grave cada arquivo na sua tabela `raw_*` (o `df.to_sql()` resolve).
- O script precisa poder rodar de novo sem duplicar linhas (pesquise `if_exists` ou use `DROP TABLE IF EXISTS`).
- Use `pathlib.Path` relativo à pasta do projeto, para o script funcionar em qualquer máquina.
- No fim, imprima a contagem de linhas de cada tabela.
- Opcional: uma função por responsabilidade (`ler_arquivos`, `carregar_tabela`, `conferir_contagens`) e o caminho do banco como argumento de linha de comando.

**Conferência**
- As contagens batem com o número de linhas de cada CSV?
- Compare com as tabelas do `conciliacao.db` de referência.
- Abra o seu banco no DBeaver e confira se os valores continuam idênticos aos do arquivo (vírgulas, espaços, datas).

### 1. Perfil dos dados
Responda com queries antes de conciliar qualquer coisa:
- Quantas linhas há em cada tabela? Qual é o período coberto?
- Como as transações se distribuem por status, tipo, método e provedor?
- Quais formatos de data, número e id aparecem em cada extrato? Há espaços, maiúsculas e minúsculas misturadas?

### 2. Staging (padronização)
Crie views ou tabelas `stg_` com tipos corretos e chaves comparáveis:
- `stg_transacoes`: valores numéricos e datas como data.
- `stg_extrato`: **um único extrato** juntando os dois provedores (`UNION ALL`), com as mesmas colunas, o mesmo `id_transacao`, os mesmos tipos de lançamento e as datas no horário de Brasília.
- Funções úteis: `TRIM`, `UPPER`, `REPLACE`, `SUBSTR`, `CAST`, `CASE`.
- Fuso e datas: no PostgreSQL, `AT TIME ZONE 'America/Sao_Paulo'` e `TO_DATE(x, 'DD/MM/YYYY')`. No SQLite, `datetime(x, '-3 hours')` e montagem da data com `SUBSTR`.

### 3. Casamento das bases
- O que está no interno e não está no extrato? E o contrário?
- Alguma transação aparece mais de uma vez no extrato? Use `GROUP BY ... HAVING` e depois refaça com `ROW_NUMBER()`.
- Dica: o PostgreSQL e o SQLite 3.39+ aceitam `FULL OUTER JOIN`. Em versões antigas do SQLite, una dois `LEFT JOIN`.

### 4. Validações
Para o que casou, confira:
- Valor bruto
- Status interno x o que o provedor fez
- Estornos
- Taxa cobrada x contrato (faça o `JOIN` com `taxas_contratadas`)
- Data de liquidação x prazo do contrato

Para cada achado, pergunte: isso é erro de verdade ou uma armadilha?

### 5. Relatório
- Uma tabela `divergencias` com as colunas `chave`, `provedor`, `categoria`, `impacto_r$` e `detalhe`.
- Um resumo por categoria e provedor: quantidade e impacto em reais.
- Para cada categoria: quem precisa agir, o provedor ou o time interno? Qual é o risco (financeiro, cliente sem crédito, contábil)?
- Algum erro se concentra em um provedor ou em um período? Se sim, isso é um incidente, não um caso isolado.

### 6. Conferência com o gabarito
- Carregue o gabarito e calcule **precisão** (dos que você marcou, quantos estão certos) e **recall** (dos que existem, quantos você achou) por categoria.
- O que você deixou passar? O que marcou que não era erro?
- Depois, gere uma massa nova com outra `--seed`, rode de novo o `carregar_dados.py` e os seus SQLs sem mexer neles. Eles continuam acertando?

### 7. Portfólio
- Um `src/pipeline.py` que roda tudo em ordem: a carga, os SQLs de `00` a `05` e a exportação do relatório (CSV ou Excel). Quem clonar o repositório deve conseguir rodar o projeto do zero com um único comando.
- Um `requirements.txt` com as bibliotecas usadas.
- Um README em português e inglês com o problema, a arquitetura (CSV → raw → staging → conciliação → relatório), os principais achados com números, por que os dados são sintéticos (sigilo e LGPD; cenários baseados na experiência prática) e como rodar o projeto.
- Opcional: um gráfico do impacto por categoria. Ele vai servir de ponte para o projeto 2.
