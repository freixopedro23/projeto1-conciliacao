DROP TABLE IF EXISTS RAW_EXTRATO_LIQUIDAPAY;
DROP TABLE IF EXISTS RAW_EXTRATO_PAGAJA;
DROP TABLE IF EXISTS RAW_TAXAS_CONTRATADAS;
DROP TABLE IF EXISTS RAW_TRANSACOES_INTERNAS;

CREATE TABLE RAW_EXTRATO_LIQUIDAPAY (
    merchant_reference        TEXT,
    entry_type                TEXT,
    transaction_datetime_utc  TEXT,
    gross_amount              TEXT,
    fee                       TEXT,
    net_amount                TEXT,
    currency                  TEXT,
    settlement_date           TEXT
);

CREATE TABLE RAW_EXTRATO_PAGAJA (
    pedido        			  TEXT,
    operacao                  TEXT,
    data_operacao  			  TEXT,
    valor_bruto               TEXT,
    taxa                      TEXT,
    valor_liquido             TEXT,
	data_liquidacao			  TEXT
);

CREATE TABLE RAW_TAXAS_CONTRATADAS (
    provedor        		  TEXT,
    metodo                    TEXT,
    tipo  			  		  TEXT,
    taxa_pct                  TEXT,
    taxa_fixa                 TEXT,
    prazo_liquidacao_dias     TEXT
);

CREATE TABLE RAW_TRANSACOES_INTERNAS (
    id_transacao        	  TEXT,
    id_cliente                TEXT,
    tipo  					  TEXT,
    metodo              	  TEXT,
    provedor                  TEXT,
    valor                	  TEXT,
    status                    TEXT,
    criado_em           	  TEXT,
	atualizado_em			  TEXT
);
