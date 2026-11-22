-- =====================================================================
-- 06_conferencia.sql  –  Etapa 6: conferência com o gabarito (PostgreSQL)
--
-- Compara a tabela divergencias (etapa 5) com o gabarito do gerador
-- (raw_gabarito) e mede o acerto do pipeline:
--   precisão = VP / (VP + FP)  -> dos achados marcados, quantos são erros de verdade
--   recall   = VP / (VP + FN)  -> dos erros que existem, quantos foram encontrados
--
-- Um achado só conta como acerto se a transação E a categoria baterem:
-- a transação certa com o diagnóstico errado levaria à ação errada.
--
-- Saída: view conc_comparacao (uma linha por achado, com o resultado)
-- =====================================================================


-- =====================================================================
-- 6.1 COMPARAÇÃO LINHA A LINHA
-- FULL OUTER JOIN pela chave transação + categoria. Só há três casos:
--   os dois lados preenchidos -> VP (marcado e era erro)
--   só a divergencias         -> FP (marcado, mas não era erro: armadilha)
--   só o gabarito             -> FN (era erro e passou despercebido)
-- O ELSE garante que nenhuma linha fica sem classificação.
-- =====================================================================
CREATE OR REPLACE VIEW conc_comparacao AS
SELECT
    COALESCE(d.chave,     g.chave)                       AS chave,
    COALESCE(d.provedor,  g.provedor)                    AS provedor,
    COALESCE(d.categoria, g.categoria)                   AS categoria,
    CASE
        WHEN d.chave IS NOT NULL AND g.chave IS NOT NULL THEN 'VP'
        WHEN g.chave IS NULL                             THEN 'FP'
        ELSE                                                  'FN'
    END                                                  AS resultado,
    d.impacto_rs                                         AS impacto_pipeline,
    g.impacto_rs::numeric(12,2)                          AS impacto_gabarito,
    d.detalhe                                            AS detalhe_pipeline,
    g.detalhe                                            AS detalhe_gabarito
FROM divergencias AS d
FULL OUTER JOIN raw_gabarito AS g
  ON  g.chave     = d.chave
  AND g.categoria = d.categoria;


-- =====================================================================
-- 6.2 PRECISÃO E RECALL POR CATEGORIA, COM TOTAL
-- ROLLUP gera uma linha por categoria e uma linha extra de total
-- (categoria nula, exibida como TOTAL).
-- O 100.0 antes da divisão evita a divisão inteira (9 / 10 = 0);
-- o NULLIF evita a divisão por zero numa categoria sem achados.
-- O total é a média micro: soma VP, FP e FN de todas as categorias e só
-- depois divide (a média macro seria a média das taxas das categorias).
-- =====================================================================
WITH contagem AS (
    SELECT
        categoria,
        COUNT(*) FILTER (WHERE resultado = 'VP')  AS vp,
        COUNT(*) FILTER (WHERE resultado = 'FP')  AS fp,
        COUNT(*) FILTER (WHERE resultado = 'FN')  AS fn
    FROM conc_comparacao
    GROUP BY ROLLUP (categoria)
)
SELECT
    COALESCE(categoria, 'TOTAL')                AS categoria,
    vp,
    fp,
    fn,
    ROUND(100.0 * vp / NULLIF(vp + fp, 0), 2)   AS precisao_pct,
    ROUND(100.0 * vp / NULLIF(vp + fn, 0), 2)   AS recall_pct
FROM contagem
ORDER BY categoria IS NULL, categoria;          -- TOTAL por último
-- Resultado (seed 42): 8 categorias, 125 VP, 0 FP, 0 FN.
-- Precisão e recall de 100% em todas as categorias e no total.


-- =====================================================================
-- 6.3 O QUE ERROU: FALSOS POSITIVOS E FALSOS NEGATIVOS
-- Lista para investigar. Em cada caso, a pergunta é: a regra do SQL
-- está errada, ou o caso é uma armadilha que a regra não previu?
-- =====================================================================
SELECT
    resultado,
    categoria,
    chave,
    provedor,
    COALESCE(detalhe_pipeline, detalhe_gabarito)  AS detalhe
FROM conc_comparacao
WHERE resultado IN ('FP', 'FN')
ORDER BY resultado, categoria, chave;
-- Resultado (seed 42): nenhuma linha.


-- =====================================================================
-- 6.4 O IMPACTO TAMBÉM CONFERE?
-- Acertar o achado não basta: o valor em R$ precisa bater com o
-- gabarito. O gabarito traz o impacto em valor absoluto, então a
-- comparação usa ABS no lado do pipeline.
-- =====================================================================
SELECT
    categoria,
    COUNT(*)                                                         AS qt_vp,
    COUNT(*) FILTER (WHERE ABS(impacto_pipeline) <> impacto_gabarito) AS qt_impacto_diferente,
    SUM(ABS(impacto_pipeline))                                       AS vl_pipeline,
    SUM(impacto_gabarito)                                            AS vl_gabarito
FROM conc_comparacao
WHERE resultado = 'VP'
GROUP BY categoria
ORDER BY categoria;
-- Resultado (seed 42): 125 VP, 0 FP, 0 FN. Precisão e recall de 100%.
-- Resultado (seed 7, sem nenhuma mudança nos SQLs): 123 VP, 0 FP, 0 FN.
--   Precisão e recall de 100%. As regras não dependem da massa original.