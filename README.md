# Conciliação de Pagamentos com SQL

**Português** · [English](README.en.md)

Pipeline em SQL e Python que concilia o que o sistema interno de uma plataforma registrou com o que dois provedores de pagamento liquidaram, encontra as divergências, calcula o impacto em reais, diz quem precisa agir e mede o próprio acerto contra um gabarito.

**Resultado:** 125 divergências em 8 categorias, R$ 21.294,81 de impacto, dois incidentes identificados e **100% de precisão e recall**, inclusive numa massa de dados nova, sem alterar nenhuma consulta.

---

## O problema

Uma plataforma online fictícia recebe depósitos e paga saques por dois provedores, também fictícios: **PagaJá** e **LiquidaPay**. Fechou outubro de 2026, e o financeiro precisa saber se o que o sistema interno registrou bate com o que os provedores liquidaram.

As três bases não conversam entre si:

| Fonte | Formato |
| --- | --- |
| Base interna | 6.000 transações; datas no horário de Brasília |
| Extrato da PagaJá | 3.021 linhas; separador `;`, vírgula decimal com ponto de milhar, datas `dd/mm/aaaa`, id sem hífen e em minúsculas |
| Extrato da LiquidaPay | 2.407 linhas; em inglês, horário em **UTC**, ids com espaços e caixa misturada |
| Contrato | Taxa (percentual + fixa) e prazo de liquidação por provedor, método e tipo |

A entrega é um **relatório de divergências**: o que não bate, por quê, quanto vale e quem precisa agir, o provedor ou o time interno.

## Por que os dados são sintéticos

Dados de transações, extratos de provedores e taxas contratadas são confidenciais e protegidos pela LGPD. Não existe base pública de conciliação de pagamentos, e usar dados reais não seria possível nem correto.

Por isso, os dados foram criados por um gerador em Python (`src/gerar_dados.py`), que reproduz problemas que aparecem na prática em operações de pagamentos: layouts diferentes por provedor, fuso horário, taxa cobrada errada numa janela de dias, lançamento duplicado, estorno que não chega ao sistema interno. Os cenários vêm da minha experiência na área; nenhum dado de empresa foi usado.

O gerador também planta **armadilhas**, casos que parecem erro mas não são, e grava um **gabarito**. Isso permite medir o acerto do pipeline, o que não seria possível com dados reais.

## Arquitetura

```
CSV  →  raw  →  staging  →  casamento  →  validações  →  relatório  →  conferência
```

| Etapa | Arquivo | O que faz |
| --- | --- | --- |
| 0. Carga | `sql/00_ddl_raw.sql`, `src/carregar_dados.py` | Cria as tabelas `raw_*` com todas as colunas em texto e carrega os CSVs sem nenhuma transformação |
| 1. Perfil | `sql/01_perfil.sql` | Exploração antes de conciliar: volumes, períodos, distribuições, formatos, ids sujos, efeito do fuso |
| 2. Staging | `sql/02_staging.sql` | Views `stg_*`: tipos corretos, ids padronizados, fuso convertido para Brasília, os dois extratos num só (`UNION ALL`) |
| 3. Casamento | `sql/03_casamento.sql` | Remove duplicatas, define o que deveria estar no extrato e cruza as bases (`FULL OUTER JOIN`) |
| 4. Validações | `sql/04_validacoes.sql` | Valor, status, estornos, taxa x contrato e prazo; junta tudo numa lista única de achados |
| 5. Relatório | `sql/05_relatorio.sql` | Tabela `divergencias`, resumo, responsável e risco por categoria, série diária com acumulado e incidentes |
| 6. Conferência | `sql/06_conferencia.sql` | Compara com o gabarito: precisão e recall por categoria |
| Orquestração | `src/pipeline.py` | Roda tudo em ordem e exporta o relatório para `saida/` |

A camada raw guarda os arquivos exatamente como chegaram. Toda a limpeza fica na staging, escrita em SQL e versionada. Assim, qualquer achado pode ser rastreado até a linha original do provedor.

## Principais achados

**125 divergências em 8 categorias:**

| Categoria | Achados | Impacto (R$) | Quem age | Risco |
| --- | --- | --- | --- | --- |
| Duplicidade | 10 | 4.693,24 | Provedor | Financeiro |
| Ausente no interno | 8 | 4.704,20 | Investigar | Cliente |
| Liquidação atrasada | 11 | 4.178,43 | Provedor | Caixa |
| Status divergente | 10 | 3.467,21 | Interno | Cliente |
| Ausente no extrato | 12 | 2.545,06 | Provedor | Financeiro |
| Estorno não registrado | 7 | 1.308,32 | Interno | Financeiro |
| Valor divergente | 9 | 289,29 | Provedor | Financeiro |
| Taxa incorreta | 58 | 109,06 | Provedor | Financeiro |
| **Total** | **125** | **21.294,81** | | |

**Contar achados engana.** A LiquidaPay tem 82 achados (R$ 4.148,64) e a PagaJá, 43 (R$ 17.146,17): o dobro de ocorrências, mas um quarto do impacto. Quem priorizasse pela contagem iria atrás do provedor errado.

**Dois incidentes, não casos isolados:**

1. **Taxa incorreta na LiquidaPay (cartão):** 58 transações entre 15 e 18/10, todas com a taxa acima do contrato. O valor é baixo (R$ 109,06), mas o padrão indica uma configuração de taxa errada no provedor. Esse incidente quase não aparece na série de **valor**; na série de **quantidade**, o acumulado salta de 19 para 77 em quatro dias.
2. **Duplicidade na PagaJá:** 10 lançamentos repetidos, todos liquidados em 22/10. É o maior impacto entre as categorias (R$ 4.693,24), e um único dia de liquidação sugere um lote processado duas vezes.

As demais categorias aparecem espalhadas pelo mês e nos dois provedores: são falhas pontuais, tratadas uma a uma.

### Armadilhas que não viraram falso alarme

| Armadilha | Tamanho | Como foi tratada |
| --- | --- | --- |
| Transações do fim do mês que só liquidam em novembro | 95 | Fora do esperado: o extrato vai até 31/10. Sem essa regra, apareceriam como "ausentes" |
| Diferença de R$ 0,01 na taxa por arredondamento | 776 | Tolerância de R$ 0,01 prevista no contrato |
| Lançamentos que mudam de dia ao converter UTC para Brasília | 517 | Fuso convertido na staging, antes de qualquer comparação de data |
| Estornos com o mesmo id do lançamento original | 175 | O tipo de lançamento entra na definição de duplicidade |
| Ids com espaço ou caixa fora do padrão | 272 | `TRIM` + `UPPER` na staging |
| Valores com ponto de milhar e vírgula decimal | 150 | Remover o ponto antes de trocar a vírgula |

## Validação

O gerador grava um gabarito com todas as divergências plantadas. A etapa 6 compara o resultado do pipeline com ele, linha a linha, pela chave **transação + categoria**: achar a transação certa com o diagnóstico errado não conta como acerto.

| Massa | Achados | Precisão | Recall |
| --- | --- | --- | --- |
| Original (seed 42) | 125 | 100% | 100% |
| Nova, gerada com `--seed 7`, **sem alterar nenhuma consulta** | 123 | 100% | 100% |

O impacto em reais dos 125 achados também bate com o gabarito.

A seed 7 mostra que as regras seguem a lógica de negócio, e não detalhes da massa original: os erros caem em outras transações, outros dias e outros valores. O limite do teste: as duas massas vêm do mesmo gerador, com os mesmos tipos de erro. Um tipo de erro novo exigiria uma validação nova (ver "Próximos passos").

## Técnicas de SQL

| Técnica | Onde | Para quê |
| --- | --- | --- |
| CTEs encadeadas | Etapas 3 a 6 | Cada passo da lógica com nome próprio, sem subconsultas aninhadas |
| `ROW_NUMBER()` | `03_casamento.sql` | Separar a primeira ocorrência de cada lançamento das repetidas |
| `COUNT(*) OVER (PARTITION BY ...)` | `03_casamento.sql` | Guardar quantas vezes o lançamento apareceu, mesmo depois de deduplicar |
| `LAG()` com cláusula `WINDOW` | `04_validacoes.sql` | Olhar o lançamento anterior de cada transação e conferir a sequência dos estornos |
| `SUM() OVER (PARTITION BY ... ORDER BY ...)` | `05_relatorio.sql` | Impacto e quantidade acumulados ao longo do mês, por provedor |
| `FULL OUTER JOIN` | Etapas 3 e 6 | Encontrar o que existe só de um lado (interno x extrato; pipeline x gabarito) |
| `generate_series` + `CROSS JOIN` | `05_relatorio.sql` | Série com todos os dias do mês, inclusive os sem achado |
| `GROUPING SETS` e `ROLLUP` | Etapas 1 e 6 | Várias agregações numa consulta; subtotal e total |
| `COUNT(*) FILTER (WHERE ...)` | Várias | Contagens condicionais numa única passada |
| `AT TIME ZONE` e `TO_DATE` com máscara | `02_staging.sql` | Fuso e datas convertidos de forma explícita, sem depender da configuração do servidor |
| `INSERT ... SELECT` com chave composta | `05_relatorio.sql` | O relatório como "foto" do fechamento, com uma linha por transação e categoria |

## Como rodar

**Requisitos:** Python 3.11 ou superior e PostgreSQL 14 ou superior.

1. Clone o repositório e instale as dependências (de preferência num ambiente virtual):
   ```bash
   python -m venv .venv
   pip install -r requirements.txt
   ```
2. Crie o banco no PostgreSQL:
   ```sql
   CREATE DATABASE conciliacao;
   ```
3. Crie um arquivo `.env` na raiz do projeto (ele não vai para o repositório):
   ```
   PG_USER=postgres
   PG_PASSWORD=sua_senha
   PG_HOST=localhost
   PG_PORT=5432
   PG_DB=conciliacao
   ```
4. Rode o pipeline:
   ```bash
   python src/pipeline.py
   ```

Saída esperada no fim: `125 achados | precisão 100.0% | recall 100.0%`. O relatório fica em `saida/`: `divergencias.csv`, `resumo.csv` e `relatorio_conciliacao.xlsx`.

**Para testar com outra massa:**
```bash
python src/gerar_dados.py --seed 7
python src/pipeline.py
python src/gerar_dados.py          # volta para a massa original (seed 42)
```

## Estrutura do repositório

```
├── dados/             CSVs de entrada (gerados por src/gerar_dados.py)
├── gabarito/          divergências plantadas, usadas só na etapa 6
├── sql/               00_ddl_raw.sql a 06_conferencia.sql
├── src/
│   ├── gerar_dados.py     gerador da massa sintética
│   ├── carregar_dados.py  carga dos CSVs nas tabelas raw
│   └── pipeline.py        roda tudo e exporta o relatório
├── saida/             relatório gerado pelo pipeline
├── DESAFIO.md         enunciado completo do projeto
└── requirements.txt
```

## Próximos passos

- **Um tipo de erro novo no gerador** (chargeback ou liquidação parcial), para testar o pipeline contra um problema que ele ainda não conhece e criar a validação correspondente.
- **Perguntas em linguagem natural:** um agente que responde perguntas em português sobre o banco da conciliação, com SQL somente de leitura e respostas conferidas contra consultas conhecidas.
- **Webhooks em JSON:** o histórico de status de cada transação, extraído com SQL.

---

Feito por **Pedro Freixo** · [GitHub](https://github.com/freixopedro23)
