-- =====================================================================
-- saas-driving-school-api · schema PostgreSQL
-- Compatível com PostgreSQL >= 14 (validado em 16). Neon e Docker local.
--
-- FONTE DE VERDADE DA BASE DE DADOS. As entidades da API (TypeORM) são
-- geradas 1:1 a partir deste ficheiro. Ver BACKEND_KB.md, secção 5.
--
-- Convenções:
--   * Nomes de tabelas e colunas em português, snake_case, sem acentos.
--   * PK: uuid (gen_random_uuid()), excepto `auditoria` (bigint identity)
--     e tabelas de associação com PK composta.
--   * Multi-tenant: toda a tabela de negócio tem `escola_id`. O isolamento
--     é aplicado pela API (ver BACKEND_KB.md, secção 6).
--   * Soft delete: `eliminado_em` (NULL = ativo). Unicidades de negócio
--     são índices parciais `WHERE eliminado_em IS NULL`.
--   * Dinheiro: numeric(14,2) em AOA. Nunca float.
--   * Datas/horas: timestamptz (instantes) e date/time (calendário).
--     Fuso de negócio: Africa/Luanda (UTC+1, sem horário de verão).
--   * "Enums" são varchar + CHECK (fácil de evoluir). Os valores estão
--     espelhados em BACKEND_KB.md (anexo A) e FRONTEND_KB.md.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- pesquisa por semelhança
CREATE EXTENSION IF NOT EXISTS unaccent;     -- pesquisa sem acentos
CREATE EXTENSION IF NOT EXISTS citext;       -- emails case-insensitive
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- anti-conflito de agenda

-- ---------------------------------------------------------------------
-- Funções utilitárias
-- ---------------------------------------------------------------------

-- unaccent() é STABLE; este wrapper é IMMUTABLE para poder ser usado em índices.
CREATE OR REPLACE FUNCTION f_unaccent(texto text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
AS $$ SELECT public.unaccent('public.unaccent'::regdictionary, texto) $$;

-- "Hoje" no fuso de negócio (o servidor/Neon corre em UTC).
CREATE OR REPLACE FUNCTION f_hoje() RETURNS date
LANGUAGE sql STABLE
AS $$ SELECT (now() AT TIME ZONE 'Africa/Luanda')::date $$;

CREATE OR REPLACE FUNCTION trg_set_atualizado_em() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;

-- =====================================================================
-- 1. TENANT (ESCOLA) E SaaS
-- =====================================================================

CREATE TABLE escola (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome                    varchar(200) NOT NULL,
  nome_curto              varchar(60),
  slug                    varchar(60)  NOT NULL,
  nif                     varchar(30),
  email                   citext,
  telefone                varchar(30),
  website                 varchar(200),
  endereco                varchar(300),
  provincia               varchar(80),
  municipio               varchar(80),
  alvara_numero           varchar(60),
  alvara_validade         date,
  estado                  varchar(12)  NOT NULL DEFAULT 'PENDENTE',
  onboarding_passos       text[]       NOT NULL DEFAULT '{}',
  onboarding_concluido_em timestamptz,
  criado_em               timestamptz  NOT NULL DEFAULT now(),
  atualizado_em           timestamptz  NOT NULL DEFAULT now(),
  eliminado_em            timestamptz,
  CONSTRAINT ck_escola_estado CHECK (estado IN ('PENDENTE','ATIVA','SUSPENSA','CANCELADA')),
  CONSTRAINT ck_escola_slug   CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);
CREATE UNIQUE INDEX ux_escola_slug ON escola (slug) WHERE eliminado_em IS NULL;

COMMENT ON COLUMN escola.onboarding_passos IS
  'Chaves dos passos de onboarding concluídos: DADOS_ESCOLA, IDENTIDADE, FILIAL, CATEGORIAS, EQUIPA, REVISAO.';

-- Identidade visual e documental da escola (usada pelo front e pelos PDFs/Excel).
CREATE TABLE escola_identidade (
  escola_id            uuid PRIMARY KEY REFERENCES escola(id) ON DELETE CASCADE,
  logo_key             varchar(400),
  logo_escuro_key      varchar(400),
  favicon_key          varchar(400),
  assinatura_key       varchar(400),
  carimbo_key          varchar(400),
  cor_primaria         varchar(7)  NOT NULL DEFAULT '#2563EB',
  cor_secundaria       varchar(7),
  cor_destaque         varchar(7),
  tema_padrao          varchar(10) NOT NULL DEFAULT 'SISTEMA',
  fonte                varchar(60) NOT NULL DEFAULT 'Plus Jakarta Sans',
  cabecalho_documentos text,
  rodape_documentos    text,
  moeda                varchar(3)  NOT NULL DEFAULT 'AOA',
  fuso_horario         varchar(60) NOT NULL DEFAULT 'Africa/Luanda',
  idioma               varchar(10) NOT NULL DEFAULT 'pt-AO',
  criado_em            timestamptz NOT NULL DEFAULT now(),
  atualizado_em        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_identidade_tema CHECK (tema_padrao IN ('CLARO','ESCURO','SISTEMA')),
  CONSTRAINT ck_identidade_cor_primaria   CHECK (cor_primaria ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT ck_identidade_cor_secundaria CHECK (cor_secundaria IS NULL OR cor_secundaria ~ '^#[0-9A-Fa-f]{6}$'),
  CONSTRAINT ck_identidade_cor_destaque   CHECK (cor_destaque IS NULL OR cor_destaque ~ '^#[0-9A-Fa-f]{6}$')
);

-- Regras operacionais configuráveis por escola (valores iniciais editáveis).
CREATE TABLE escola_configuracao (
  escola_id                       uuid PRIMARY KEY REFERENCES escola(id) ON DELETE CASCADE,
  duracao_aula_pratica_min        smallint     NOT NULL DEFAULT 50,
  duracao_aula_teorica_min        smallint     NOT NULL DEFAULT 50,
  antecedencia_cancelamento_horas smallint     NOT NULL DEFAULT 24,
  agendar_sem_pagamento_em_dia    boolean      NOT NULL DEFAULT false,
  nota_maxima                     numeric(5,2) NOT NULL DEFAULT 20,
  nota_minima_aprovacao           numeric(5,2) NOT NULL DEFAULT 10,
  criado_em                       timestamptz  NOT NULL DEFAULT now(),
  atualizado_em                   timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_config_duracao_pratica CHECK (duracao_aula_pratica_min > 0),
  CONSTRAINT ck_config_duracao_teorica CHECK (duracao_aula_teorica_min > 0),
  CONSTRAINT ck_config_antecedencia    CHECK (antecedencia_cancelamento_horas >= 0),
  CONSTRAINT ck_config_notas           CHECK (nota_maxima > 0 AND nota_minima_aprovacao >= 0 AND nota_minima_aprovacao <= nota_maxima)
);

-- Janelas em que aulas práticas são permitidas (regulamentação / política da escola).
-- Sem linhas = sem restrição. dia_semana segue ISO: 1 = segunda ... 7 = domingo.
CREATE TABLE janela_aula_pratica (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id   uuid        NOT NULL REFERENCES escola(id) ON DELETE CASCADE,
  dia_semana  smallint    NOT NULL,
  hora_inicio time        NOT NULL,
  hora_fim    time        NOT NULL,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_janela_dia  CHECK (dia_semana BETWEEN 1 AND 7),
  CONSTRAINT ck_janela_hora CHECK (hora_fim > hora_inicio)
);
CREATE INDEX ix_janela_escola ON janela_aula_pratica (escola_id, dia_semana);

CREATE TABLE plano (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo             varchar(30)  NOT NULL UNIQUE,
  nome               varchar(100) NOT NULL,
  descricao          varchar(300),
  preco_mensal       numeric(14,2) NOT NULL DEFAULT 0,
  limite_estudantes  integer,
  limite_utilizadores integer,
  limite_filiais     integer,
  ativo              boolean      NOT NULL DEFAULT true,
  criado_em          timestamptz  NOT NULL DEFAULT now(),
  atualizado_em      timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_plano_preco CHECK (preco_mensal >= 0)
);

CREATE TABLE subscricao (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id        uuid        NOT NULL REFERENCES escola(id),
  plano_id         uuid        NOT NULL REFERENCES plano(id),
  estado           varchar(12) NOT NULL DEFAULT 'TESTE',
  inicio           date        NOT NULL DEFAULT CURRENT_DATE,
  fim              date,
  proxima_cobranca date,
  criado_em        timestamptz NOT NULL DEFAULT now(),
  atualizado_em    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_subscricao_estado CHECK (estado IN ('TESTE','ATIVA','EM_ATRASO','CANCELADA')),
  CONSTRAINT ck_subscricao_datas  CHECK (fim IS NULL OR fim >= inicio)
);
CREATE UNIQUE INDEX ux_subscricao_vigente ON subscricao (escola_id)
  WHERE estado IN ('TESTE','ATIVA','EM_ATRASO');

CREATE TABLE filial (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id     uuid         NOT NULL REFERENCES escola(id),
  codigo        varchar(20)  NOT NULL,
  nome          varchar(150) NOT NULL,
  endereco      varchar(300),
  provincia     varchar(80),
  municipio     varchar(80),
  telefone      varchar(30),
  email         citext,
  principal     boolean      NOT NULL DEFAULT false,
  ativa         boolean      NOT NULL DEFAULT true,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  atualizado_em timestamptz  NOT NULL DEFAULT now(),
  eliminado_em  timestamptz
);
CREATE UNIQUE INDEX ux_filial_codigo    ON filial (escola_id, upper(codigo)) WHERE eliminado_em IS NULL;
CREATE UNIQUE INDEX ux_filial_principal ON filial (escola_id) WHERE principal AND eliminado_em IS NULL;

-- =====================================================================
-- 2. ACESSO: UTILIZADORES, PERFIS E PERMISSÕES
-- =====================================================================

-- tipo = PLATAFORMA -> escola_id NULL (equipa do SaaS). tipo = ESCOLA -> escola_id obrigatório.
-- Email único globalmente (login sem escolher escola).
CREATE TABLE utilizador (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id          uuid REFERENCES escola(id),
  tipo               varchar(10)  NOT NULL DEFAULT 'ESCOLA',
  nome               varchar(200) NOT NULL,
  email              citext       NOT NULL,
  telefone           varchar(30),
  senha_hash         varchar(255) NOT NULL,
  foto_key           varchar(400),
  ativo              boolean      NOT NULL DEFAULT true,
  deve_alterar_senha boolean      NOT NULL DEFAULT true,
  perm_version       integer      NOT NULL DEFAULT 1,
  ultimo_login_em    timestamptz,
  criado_em          timestamptz  NOT NULL DEFAULT now(),
  atualizado_em      timestamptz  NOT NULL DEFAULT now(),
  eliminado_em       timestamptz,
  CONSTRAINT ck_utilizador_tipo CHECK (tipo IN ('PLATAFORMA','ESCOLA')),
  CONSTRAINT ck_utilizador_tipo_escola CHECK (
    (tipo = 'PLATAFORMA' AND escola_id IS NULL) OR (tipo = 'ESCOLA' AND escola_id IS NOT NULL)
  )
);
CREATE UNIQUE INDEX ux_utilizador_email  ON utilizador (email) WHERE eliminado_em IS NULL;
CREATE INDEX        ix_utilizador_escola ON utilizador (escola_id) WHERE eliminado_em IS NULL;

COMMENT ON COLUMN utilizador.perm_version IS
  'Incrementar sempre que perfis/permissões do utilizador mudam. Vai no JWT (pv) e invalida tokens/caches antigos.';

-- Catálogo global de permissões (sincronizado a partir do código no arranque).
CREATE TABLE permissao (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo        varchar(80)  NOT NULL UNIQUE,
  modulo        varchar(40)  NOT NULL,
  descricao     varchar(250) NOT NULL,
  sensivel      boolean      NOT NULL DEFAULT false,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  atualizado_em timestamptz  NOT NULL DEFAULT now()
);

-- Perfis (grupos) por escola. Perfis de sistema nascem de `perfil_modelo`.
CREATE TABLE perfil (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id     uuid         NOT NULL REFERENCES escola(id),
  chave         varchar(40),
  nome          varchar(100) NOT NULL,
  descricao     varchar(300),
  e_sistema     boolean      NOT NULL DEFAULT false,
  protegido     boolean      NOT NULL DEFAULT false,
  ativo         boolean      NOT NULL DEFAULT true,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  atualizado_em timestamptz  NOT NULL DEFAULT now(),
  eliminado_em  timestamptz,
  CONSTRAINT ck_perfil_protegido CHECK (NOT protegido OR e_sistema)
);
CREATE UNIQUE INDEX ux_perfil_nome  ON perfil (escola_id, lower(nome)) WHERE eliminado_em IS NULL;
CREATE UNIQUE INDEX ux_perfil_chave ON perfil (escola_id, chave) WHERE chave IS NOT NULL AND eliminado_em IS NULL;

COMMENT ON COLUMN perfil.protegido IS
  'Perfil ADMINISTRADOR: não pode ser eliminado nem editado; tem sempre todas as permissões (calculado em código).';

-- Modelos de perfil globais, clonados para cada escola no provisionamento.
CREATE TABLE perfil_modelo (
  chave     varchar(40)  PRIMARY KEY,
  nome      varchar(100) NOT NULL,
  descricao varchar(300),
  protegido boolean      NOT NULL DEFAULT false,
  ordem     smallint     NOT NULL DEFAULT 0
);

CREATE TABLE perfil_modelo_permissao (
  perfil_modelo_chave varchar(40) NOT NULL REFERENCES perfil_modelo(chave) ON DELETE CASCADE,
  permissao_id        uuid        NOT NULL REFERENCES permissao(id) ON DELETE CASCADE,
  escopo              varchar(10) NOT NULL,
  PRIMARY KEY (perfil_modelo_chave, permissao_id),
  CONSTRAINT ck_pmp_escopo CHECK (escopo IN ('ESCOLA','FILIAL','PROPRIO'))
);

CREATE TABLE perfil_permissao (
  perfil_id    uuid        NOT NULL REFERENCES perfil(id) ON DELETE CASCADE,
  permissao_id uuid        NOT NULL REFERENCES permissao(id) ON DELETE CASCADE,
  escopo       varchar(10) NOT NULL DEFAULT 'FILIAL',
  criado_em    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (perfil_id, permissao_id),
  CONSTRAINT ck_perfil_permissao_escopo CHECK (escopo IN ('ESCOLA','FILIAL','PROPRIO'))
);

COMMENT ON COLUMN perfil_permissao.escopo IS
  'ESCOLA = todas as filiais; FILIAL = filiais do utilizador; PROPRIO = só registos ligados ao próprio utilizador.';

-- Um utilizador pode ter vários perfis; filial_id NULL = perfil válido em todas as filiais dele.
CREATE TABLE utilizador_perfil (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  utilizador_id uuid        NOT NULL REFERENCES utilizador(id) ON DELETE CASCADE,
  perfil_id     uuid        NOT NULL REFERENCES perfil(id),
  filial_id     uuid        REFERENCES filial(id),
  criado_por    uuid        REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_utilizador_perfil ON utilizador_perfil
  (utilizador_id, perfil_id, COALESCE(filial_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX ix_utilizador_perfil_perfil ON utilizador_perfil (perfil_id);

-- Exceções individuais. DENY vence sempre ALLOW e perfis.
CREATE TABLE utilizador_permissao (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  utilizador_id uuid         NOT NULL REFERENCES utilizador(id) ON DELETE CASCADE,
  permissao_id  uuid         NOT NULL REFERENCES permissao(id) ON DELETE CASCADE,
  efeito        varchar(5)   NOT NULL,
  escopo        varchar(10)  NOT NULL DEFAULT 'FILIAL',
  motivo        varchar(300),
  expira_em     timestamptz,
  criado_por    uuid         REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_utilizador_permissao_efeito CHECK (efeito IN ('ALLOW','DENY')),
  CONSTRAINT ck_utilizador_permissao_escopo CHECK (escopo IN ('ESCOLA','FILIAL','PROPRIO')),
  CONSTRAINT uq_utilizador_permissao UNIQUE (utilizador_id, permissao_id)
);

-- Filiais a que o utilizador tem acesso (limita o escopo FILIAL).
CREATE TABLE utilizador_filial (
  utilizador_id uuid        NOT NULL REFERENCES utilizador(id) ON DELETE CASCADE,
  filial_id     uuid        NOT NULL REFERENCES filial(id) ON DELETE CASCADE,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (utilizador_id, filial_id)
);

-- Refresh tokens com rotação. Guardar apenas o hash (SHA-256 hex) do token.
CREATE TABLE sessao_refresh_token (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  utilizador_id  uuid         NOT NULL REFERENCES utilizador(id) ON DELETE CASCADE,
  familia_id     uuid         NOT NULL,
  token_hash     varchar(128) NOT NULL UNIQUE,
  expira_em      timestamptz  NOT NULL,
  revogado_em    timestamptz,
  substituido_por uuid,
  ip             varchar(64),
  user_agent     varchar(300),
  criado_em      timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX ix_refresh_utilizador ON sessao_refresh_token (utilizador_id) WHERE revogado_em IS NULL;
CREATE INDEX ix_refresh_familia    ON sessao_refresh_token (familia_id);

CREATE TABLE auditoria (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  escola_id     uuid REFERENCES escola(id),
  utilizador_id uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  acao          varchar(80)  NOT NULL,
  entidade      varchar(60),
  entidade_id   varchar(64),
  dados_antes   jsonb,
  dados_depois  jsonb,
  ip            varchar(64),
  user_agent    varchar(300),
  criado_em     timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX ix_auditoria_escola_data ON auditoria (escola_id, criado_em DESC);
CREATE INDEX ix_auditoria_entidade    ON auditoria (escola_id, entidade, entidade_id);

-- =====================================================================
-- 3. CONFIGURAÇÃO DA FORMAÇÃO
-- =====================================================================

CREATE TABLE categoria_carta (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id     uuid         NOT NULL REFERENCES escola(id),
  codigo        varchar(10)  NOT NULL,
  nome          varchar(100) NOT NULL,
  descricao     varchar(300),
  idade_minima  smallint     NOT NULL DEFAULT 18,
  ativa         boolean      NOT NULL DEFAULT true,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  atualizado_em timestamptz  NOT NULL DEFAULT now(),
  eliminado_em  timestamptz,
  CONSTRAINT ck_categoria_idade CHECK (idade_minima BETWEEN 14 AND 99)
);
CREATE UNIQUE INDEX ux_categoria_codigo ON categoria_carta (escola_id, upper(codigo)) WHERE eliminado_em IS NULL;

CREATE TABLE curriculo (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id              uuid         NOT NULL REFERENCES escola(id),
  categoria_id           uuid         NOT NULL REFERENCES categoria_carta(id),
  nome                   varchar(150) NOT NULL,
  aulas_teoricas_minimas smallint     NOT NULL DEFAULT 0,
  aulas_praticas_minimas smallint     NOT NULL DEFAULT 0,
  vigente_desde          date         NOT NULL DEFAULT CURRENT_DATE,
  vigente_ate            date,
  ativo                  boolean      NOT NULL DEFAULT true,
  criado_em              timestamptz  NOT NULL DEFAULT now(),
  atualizado_em          timestamptz  NOT NULL DEFAULT now(),
  eliminado_em           timestamptz,
  CONSTRAINT ck_curriculo_minimos CHECK (aulas_teoricas_minimas >= 0 AND aulas_praticas_minimas >= 0),
  CONSTRAINT ck_curriculo_vigencia CHECK (vigente_ate IS NULL OR vigente_ate >= vigente_desde)
);
CREATE INDEX ix_curriculo_categoria ON curriculo (escola_id, categoria_id) WHERE eliminado_em IS NULL;

CREATE TABLE curriculo_modulo (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id      uuid         NOT NULL REFERENCES escola(id),
  curriculo_id   uuid         NOT NULL REFERENCES curriculo(id) ON DELETE CASCADE,
  ordem          smallint     NOT NULL,
  nome           varchar(150) NOT NULL,
  tipo           varchar(10)  NOT NULL,
  aulas_previstas smallint    NOT NULL DEFAULT 1,
  descricao      text,
  criado_em      timestamptz  NOT NULL DEFAULT now(),
  atualizado_em  timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_modulo_tipo   CHECK (tipo IN ('TEORICO','PRATICO')),
  CONSTRAINT ck_modulo_aulas  CHECK (aulas_previstas > 0),
  CONSTRAINT uq_modulo_ordem  UNIQUE (curriculo_id, ordem)
);

CREATE TABLE pacote (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id                 uuid          NOT NULL REFERENCES escola(id),
  categoria_id              uuid          NOT NULL REFERENCES categoria_carta(id),
  nome                      varchar(150)  NOT NULL,
  descricao                 varchar(400),
  preco                     numeric(14,2) NOT NULL,
  aulas_teoricas_incluidas  smallint      NOT NULL DEFAULT 0,
  aulas_praticas_incluidas  smallint      NOT NULL DEFAULT 0,
  inclui_taxas_exame        boolean       NOT NULL DEFAULT false,
  prestacoes_max            smallint      NOT NULL DEFAULT 1,
  ativo                     boolean       NOT NULL DEFAULT true,
  criado_em                 timestamptz   NOT NULL DEFAULT now(),
  atualizado_em             timestamptz   NOT NULL DEFAULT now(),
  eliminado_em              timestamptz,
  CONSTRAINT ck_pacote_preco      CHECK (preco >= 0),
  CONSTRAINT ck_pacote_aulas      CHECK (aulas_teoricas_incluidas >= 0 AND aulas_praticas_incluidas >= 0),
  CONSTRAINT ck_pacote_prestacoes CHECK (prestacoes_max >= 1)
);
CREATE INDEX ix_pacote_categoria ON pacote (escola_id, categoria_id) WHERE eliminado_em IS NULL;

-- =====================================================================
-- 4. PESSOAS
-- =====================================================================

-- Estudante NÃO é utilizador. `utilizador_id` fica preparado para um portal futuro.
-- `numero` é o número de estudante (sequencial por escola, via fn_proximo_numero).
CREATE TABLE estudante (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id                   uuid         NOT NULL REFERENCES escola(id),
  filial_id                   uuid         NOT NULL REFERENCES filial(id),
  numero                      integer      NOT NULL,
  nome_completo               varchar(200) NOT NULL,
  data_nascimento             date,
  genero                      varchar(1),
  estado_civil                varchar(15),
  nacionalidade               varchar(60)  NOT NULL DEFAULT 'Angolana',
  naturalidade                varchar(100),
  doc_tipo                    varchar(20)  NOT NULL DEFAULT 'BI',
  doc_numero                  varchar(40)  NOT NULL,
  doc_validade                date,
  nif                         varchar(30),
  email                       citext,
  telefone                    varchar(30),
  telefone_alternativo        varchar(30),
  endereco                    varchar(300),
  provincia                   varchar(80),
  municipio                   varchar(80),
  bairro                      varchar(100),
  nome_pai                    varchar(200),
  nome_mae                    varchar(200),
  contacto_emergencia_nome    varchar(200),
  contacto_emergencia_telefone varchar(30),
  foto_key                    varchar(400),
  estado                      varchar(12)  NOT NULL DEFAULT 'ATIVO',
  observacoes                 text,
  utilizador_id               uuid UNIQUE REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_por                  uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em                   timestamptz  NOT NULL DEFAULT now(),
  atualizado_em               timestamptz  NOT NULL DEFAULT now(),
  eliminado_em                timestamptz,
  CONSTRAINT ck_estudante_genero      CHECK (genero IS NULL OR genero IN ('M','F')),
  CONSTRAINT ck_estudante_estado_civil CHECK (estado_civil IS NULL OR estado_civil IN ('SOLTEIRO','CASADO','UNIAO_DE_FACTO','DIVORCIADO','VIUVO')),
  CONSTRAINT ck_estudante_doc_tipo    CHECK (doc_tipo IN ('BI','PASSAPORTE','CARTA_RESIDENTE','OUTRO')),
  CONSTRAINT ck_estudante_estado      CHECK (estado IN ('ATIVO','INATIVO','CONCLUIDO','DESISTENTE'))
);
-- Número nunca é reutilizado (inclui eliminados).
CREATE UNIQUE INDEX ux_estudante_numero ON estudante (escola_id, numero);
CREATE UNIQUE INDEX ux_estudante_doc    ON estudante (escola_id, doc_tipo, doc_numero) WHERE eliminado_em IS NULL;
CREATE INDEX ix_estudante_filial        ON estudante (escola_id, filial_id) WHERE eliminado_em IS NULL;
CREATE INDEX ix_estudante_estado        ON estudante (escola_id, estado) WHERE eliminado_em IS NULL;
-- Pesquisa (barra global): nome sem acentos / BI. Ver BACKEND_KB.md, secção 12.
CREATE INDEX ix_estudante_nome_trgm ON estudante USING gin (f_unaccent(lower(nome_completo)) gin_trgm_ops);
CREATE INDEX ix_estudante_doc_trgm  ON estudante USING gin (upper(doc_numero) gin_trgm_ops);

COMMENT ON COLUMN estudante.utilizador_id IS 'Reservado para portal do estudante (fase futura). Hoje é sempre NULL.';

-- Instrutor/professor. `funcao` define se leciona prática, teórica ou ambas.
CREATE TABLE instrutor (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id        uuid         NOT NULL REFERENCES escola(id),
  filial_id        uuid         NOT NULL REFERENCES filial(id),
  utilizador_id    uuid UNIQUE REFERENCES utilizador(id) ON DELETE SET NULL,
  nome_completo    varchar(200) NOT NULL,
  data_nascimento  date,
  genero           varchar(1),
  doc_tipo         varchar(20)  NOT NULL DEFAULT 'BI',
  doc_numero       varchar(40)  NOT NULL,
  telefone         varchar(30),
  email            citext,
  endereco         varchar(300),
  funcao           varchar(10)  NOT NULL DEFAULT 'AMBOS',
  licenca_numero   varchar(60),
  licenca_validade date,
  data_admissao    date,
  foto_key         varchar(400),
  observacoes      text,
  ativo            boolean      NOT NULL DEFAULT true,
  criado_em        timestamptz  NOT NULL DEFAULT now(),
  atualizado_em    timestamptz  NOT NULL DEFAULT now(),
  eliminado_em     timestamptz,
  CONSTRAINT ck_instrutor_genero   CHECK (genero IS NULL OR genero IN ('M','F')),
  CONSTRAINT ck_instrutor_doc_tipo CHECK (doc_tipo IN ('BI','PASSAPORTE','CARTA_RESIDENTE','OUTRO')),
  CONSTRAINT ck_instrutor_funcao   CHECK (funcao IN ('PRATICO','TEORICO','AMBOS'))
);
CREATE UNIQUE INDEX ux_instrutor_doc    ON instrutor (escola_id, doc_tipo, doc_numero) WHERE eliminado_em IS NULL;
CREATE INDEX        ix_instrutor_filial ON instrutor (escola_id, filial_id) WHERE eliminado_em IS NULL;
CREATE INDEX        ix_instrutor_nome_trgm ON instrutor USING gin (f_unaccent(lower(nome_completo)) gin_trgm_ops);

CREATE TABLE instrutor_categoria (
  instrutor_id uuid        NOT NULL REFERENCES instrutor(id) ON DELETE CASCADE,
  categoria_id uuid        NOT NULL REFERENCES categoria_carta(id),
  criado_em    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instrutor_id, categoria_id)
);

CREATE TABLE funcionario (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id       uuid         NOT NULL REFERENCES escola(id),
  filial_id       uuid         NOT NULL REFERENCES filial(id),
  utilizador_id   uuid UNIQUE REFERENCES utilizador(id) ON DELETE SET NULL,
  nome_completo   varchar(200) NOT NULL,
  cargo           varchar(100),
  doc_tipo        varchar(20)  NOT NULL DEFAULT 'BI',
  doc_numero      varchar(40)  NOT NULL,
  telefone        varchar(30),
  email           citext,
  data_admissao   date,
  ativo           boolean      NOT NULL DEFAULT true,
  criado_em       timestamptz  NOT NULL DEFAULT now(),
  atualizado_em   timestamptz  NOT NULL DEFAULT now(),
  eliminado_em    timestamptz,
  CONSTRAINT ck_funcionario_doc_tipo CHECK (doc_tipo IN ('BI','PASSAPORTE','CARTA_RESIDENTE','OUTRO'))
);
CREATE UNIQUE INDEX ux_funcionario_doc ON funcionario (escola_id, doc_tipo, doc_numero) WHERE eliminado_em IS NULL;

-- =====================================================================
-- 5. FROTA
-- =====================================================================

CREATE TABLE veiculo (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id           uuid         NOT NULL REFERENCES escola(id),
  filial_id           uuid         NOT NULL REFERENCES filial(id),
  categoria_id        uuid         REFERENCES categoria_carta(id),
  placa               varchar(20)  NOT NULL,
  marca               varchar(60)  NOT NULL,
  modelo              varchar(60)  NOT NULL,
  ano_fabrico         smallint,
  cor                 varchar(30),
  combustivel         varchar(10),
  transmissao         varchar(10),
  dupla_comando       boolean      NOT NULL DEFAULT false,
  chassi              varchar(40),
  quilometragem_atual integer      NOT NULL DEFAULT 0,
  data_aquisicao      date,
  estado              varchar(15)  NOT NULL DEFAULT 'DISPONIVEL',
  observacoes         text,
  criado_em           timestamptz  NOT NULL DEFAULT now(),
  atualizado_em       timestamptz  NOT NULL DEFAULT now(),
  eliminado_em        timestamptz,
  CONSTRAINT ck_veiculo_ano          CHECK (ano_fabrico IS NULL OR ano_fabrico BETWEEN 1950 AND 2100),
  CONSTRAINT ck_veiculo_combustivel  CHECK (combustivel IS NULL OR combustivel IN ('GASOLINA','GASOLEO','ELETRICO','HIBRIDO','OUTRO')),
  CONSTRAINT ck_veiculo_transmissao  CHECK (transmissao IS NULL OR transmissao IN ('MANUAL','AUTOMATICA')),
  CONSTRAINT ck_veiculo_km           CHECK (quilometragem_atual >= 0),
  CONSTRAINT ck_veiculo_estado       CHECK (estado IN ('DISPONIVEL','EM_MANUTENCAO','INATIVO'))
);
CREATE UNIQUE INDEX ux_veiculo_placa  ON veiculo (escola_id, upper(placa)) WHERE eliminado_em IS NULL;
CREATE INDEX        ix_veiculo_filial ON veiculo (escola_id, filial_id) WHERE eliminado_em IS NULL;

CREATE TABLE veiculo_manutencao (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id             uuid          NOT NULL REFERENCES escola(id),
  veiculo_id            uuid          NOT NULL REFERENCES veiculo(id),
  tipo                  varchar(12)   NOT NULL,
  descricao             varchar(400)  NOT NULL,
  data_manutencao       date          NOT NULL DEFAULT CURRENT_DATE,
  custo                 numeric(14,2) NOT NULL DEFAULT 0,
  quilometragem         integer,
  oficina               varchar(150),
  proxima_data          date,
  proxima_quilometragem integer,
  criado_por            uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em             timestamptz   NOT NULL DEFAULT now(),
  atualizado_em         timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_manutencao_tipo  CHECK (tipo IN ('PREVENTIVA','CORRETIVA','INSPECAO')),
  CONSTRAINT ck_manutencao_custo CHECK (custo >= 0),
  CONSTRAINT ck_manutencao_km    CHECK (quilometragem IS NULL OR quilometragem >= 0)
);
CREATE INDEX ix_manutencao_veiculo ON veiculo_manutencao (veiculo_id, data_manutencao DESC);

CREATE TABLE veiculo_abastecimento (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id            uuid          NOT NULL REFERENCES escola(id),
  veiculo_id           uuid          NOT NULL REFERENCES veiculo(id),
  data_abastecimento   date          NOT NULL DEFAULT CURRENT_DATE,
  litros               numeric(8,2)  NOT NULL,
  valor                numeric(14,2) NOT NULL DEFAULT 0,
  quilometragem        integer,
  posto                varchar(120),
  criado_por           uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em            timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_abastecimento_litros CHECK (litros > 0),
  CONSTRAINT ck_abastecimento_valor  CHECK (valor >= 0)
);
CREATE INDEX ix_abastecimento_veiculo ON veiculo_abastecimento (veiculo_id, data_abastecimento DESC);

-- =====================================================================
-- 6. DOCUMENTOS CARREGADOS (ANEXOS)
-- =====================================================================

CREATE TABLE tipo_documento (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id     uuid         NOT NULL REFERENCES escola(id),
  aplica_a      varchar(10)  NOT NULL,
  codigo        varchar(40)  NOT NULL,
  nome          varchar(120) NOT NULL,
  obrigatorio   boolean      NOT NULL DEFAULT false,
  tem_validade  boolean      NOT NULL DEFAULT false,
  sensivel      boolean      NOT NULL DEFAULT false,
  ativo         boolean      NOT NULL DEFAULT true,
  ordem         smallint     NOT NULL DEFAULT 0,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  atualizado_em timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_tipo_documento_aplica CHECK (aplica_a IN ('ESTUDANTE','INSTRUTOR','VEICULO')),
  CONSTRAINT uq_tipo_documento UNIQUE (escola_id, aplica_a, codigo)
);

-- Exactamente um dono: estudante, instrutor ou veículo.
CREATE TABLE anexo (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id         uuid         NOT NULL REFERENCES escola(id),
  tipo_documento_id uuid         NOT NULL REFERENCES tipo_documento(id),
  estudante_id      uuid         REFERENCES estudante(id),
  instrutor_id      uuid         REFERENCES instrutor(id),
  veiculo_id        uuid         REFERENCES veiculo(id),
  ficheiro_key      varchar(400) NOT NULL,
  nome_original     varchar(255),
  mime_type         varchar(100),
  tamanho_bytes     bigint,
  validade          date,
  estado            varchar(10)  NOT NULL DEFAULT 'PENDENTE',
  observacao        varchar(300),
  carregado_por     uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  validado_por      uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  validado_em       timestamptz,
  criado_em         timestamptz  NOT NULL DEFAULT now(),
  atualizado_em     timestamptz  NOT NULL DEFAULT now(),
  eliminado_em      timestamptz,
  CONSTRAINT ck_anexo_estado  CHECK (estado IN ('PENDENTE','VALIDADO','REJEITADO')),
  CONSTRAINT ck_anexo_tamanho CHECK (tamanho_bytes IS NULL OR tamanho_bytes >= 0),
  CONSTRAINT ck_anexo_dono    CHECK (
    (estudante_id IS NOT NULL)::int + (instrutor_id IS NOT NULL)::int + (veiculo_id IS NOT NULL)::int = 1
  )
);
CREATE INDEX ix_anexo_estudante ON anexo (estudante_id) WHERE eliminado_em IS NULL AND estudante_id IS NOT NULL;
CREATE INDEX ix_anexo_instrutor ON anexo (instrutor_id) WHERE eliminado_em IS NULL AND instrutor_id IS NOT NULL;
CREATE INDEX ix_anexo_veiculo   ON anexo (veiculo_id)   WHERE eliminado_em IS NULL AND veiculo_id IS NOT NULL;

COMMENT ON COLUMN anexo.estado IS 'Expirado NÃO é estado: calcula-se por validade < f_hoje().';

-- =====================================================================
-- 7. TURMAS E MATRÍCULAS
-- =====================================================================

-- Turma = grupo de estudantes de UMA categoria, com horário recorrente, para a formação teórica.
-- `ano` = ano de `data_inicio` (garantido por CHECK) e é o filtro principal da listagem.
CREATE TABLE turma (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id                uuid         NOT NULL REFERENCES escola(id),
  filial_id                uuid         NOT NULL REFERENCES filial(id),
  categoria_id             uuid         NOT NULL REFERENCES categoria_carta(id),
  curriculo_id             uuid         REFERENCES curriculo(id),
  instrutor_responsavel_id uuid         REFERENCES instrutor(id) ON DELETE SET NULL,
  codigo                   varchar(40)  NOT NULL,
  nome                     varchar(150) NOT NULL,
  ano                      smallint     NOT NULL,
  turno                    varchar(10)  NOT NULL,
  data_inicio              date         NOT NULL,
  data_fim_prevista        date         NOT NULL,
  data_fim_real            date,
  vagas                    smallint     NOT NULL,
  dias_semana              smallint[]   NOT NULL,
  hora_inicio              time         NOT NULL,
  hora_fim                 time         NOT NULL,
  local                    varchar(150),
  estado                   varchar(10)  NOT NULL DEFAULT 'PLANEADA',
  observacoes              text,
  criado_por               uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em                timestamptz  NOT NULL DEFAULT now(),
  atualizado_em            timestamptz  NOT NULL DEFAULT now(),
  eliminado_em             timestamptz,
  CONSTRAINT ck_turma_ano     CHECK (ano = EXTRACT(YEAR FROM data_inicio)::smallint),
  CONSTRAINT ck_turma_turno   CHECK (turno IN ('MANHA','TARDE','NOITE','FIM_SEMANA')),
  CONSTRAINT ck_turma_estado  CHECK (estado IN ('PLANEADA','ABERTA','EM_CURSO','CONCLUIDA','CANCELADA')),
  CONSTRAINT ck_turma_vagas   CHECK (vagas > 0),
  CONSTRAINT ck_turma_datas   CHECK (data_fim_prevista >= data_inicio AND (data_fim_real IS NULL OR data_fim_real >= data_inicio)),
  CONSTRAINT ck_turma_horas   CHECK (hora_fim > hora_inicio),
  CONSTRAINT ck_turma_dias    CHECK (cardinality(dias_semana) BETWEEN 1 AND 7 AND dias_semana <@ ARRAY[1,2,3,4,5,6,7]::smallint[])
);
CREATE UNIQUE INDEX ux_turma_codigo     ON turma (escola_id, upper(codigo)) WHERE eliminado_em IS NULL;
CREATE INDEX ix_turma_ano               ON turma (escola_id, ano DESC) WHERE eliminado_em IS NULL;
CREATE INDEX ix_turma_ano_estado_filial ON turma (escola_id, ano, estado, filial_id) WHERE eliminado_em IS NULL;
CREATE INDEX ix_turma_ano_categoria     ON turma (escola_id, ano, categoria_id) WHERE eliminado_em IS NULL;
CREATE INDEX ix_turma_nome_trgm         ON turma USING gin (f_unaccent(lower(nome)) gin_trgm_ops);

COMMENT ON COLUMN turma.ano IS 'Ano de data_inicio (ano de abertura). Preenchido pela API; o CHECK impede incoerência.';
COMMENT ON COLUMN turma.dias_semana IS 'ISO: 1 = segunda ... 7 = domingo.';

-- Matrícula = inscrição de um estudante numa categoria, com preço acordado.
-- valor líquido = preco_acordado - desconto (calculado em código).
CREATE TABLE matricula (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id           uuid          NOT NULL REFERENCES escola(id),
  filial_id           uuid          NOT NULL REFERENCES filial(id),
  estudante_id        uuid          NOT NULL REFERENCES estudante(id),
  categoria_id        uuid          NOT NULL REFERENCES categoria_carta(id),
  curriculo_id        uuid          NOT NULL REFERENCES curriculo(id),
  pacote_id           uuid          REFERENCES pacote(id),
  codigo              varchar(30)   NOT NULL,
  estado              varchar(12)   NOT NULL DEFAULT 'PENDENTE',
  data_matricula      date          NOT NULL DEFAULT CURRENT_DATE,
  data_conclusao      date,
  preco_acordado      numeric(14,2) NOT NULL DEFAULT 0,
  desconto            numeric(14,2) NOT NULL DEFAULT 0,
  desconto_motivo     varchar(300),
  motivo_encerramento varchar(300),
  observacoes         text,
  criado_por          uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em           timestamptz   NOT NULL DEFAULT now(),
  atualizado_em       timestamptz   NOT NULL DEFAULT now(),
  eliminado_em        timestamptz,
  CONSTRAINT ck_matricula_estado   CHECK (estado IN ('PENDENTE','ATIVA','SUSPENSA','CONCLUIDA','CANCELADA','DESISTENTE','TRANSFERIDA')),
  CONSTRAINT ck_matricula_valores  CHECK (preco_acordado >= 0 AND desconto >= 0 AND desconto <= preco_acordado),
  CONSTRAINT ck_matricula_conclusao CHECK (data_conclusao IS NULL OR data_conclusao >= data_matricula)
);
CREATE UNIQUE INDEX ux_matricula_codigo ON matricula (escola_id, codigo);
-- No máximo uma matrícula "viva" por estudante e categoria.
CREATE UNIQUE INDEX ux_matricula_viva ON matricula (estudante_id, categoria_id)
  WHERE estado IN ('PENDENTE','ATIVA','SUSPENSA') AND eliminado_em IS NULL;
CREATE INDEX ix_matricula_estudante ON matricula (escola_id, estudante_id) WHERE eliminado_em IS NULL;
CREATE INDEX ix_matricula_categoria ON matricula (escola_id, categoria_id, estado) WHERE eliminado_em IS NULL;

-- Histórico de turmas da matrícula; saida_em NULL = turma atual (no máximo uma).
CREATE TABLE matricula_turma (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id    uuid         NOT NULL REFERENCES escola(id),
  matricula_id uuid         NOT NULL REFERENCES matricula(id) ON DELETE CASCADE,
  turma_id     uuid         NOT NULL REFERENCES turma(id),
  entrada_em   date         NOT NULL DEFAULT CURRENT_DATE,
  saida_em     date,
  motivo_saida varchar(300),
  criado_por   uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em    timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_matricula_turma_datas CHECK (saida_em IS NULL OR saida_em >= entrada_em)
);
CREATE UNIQUE INDEX ux_matricula_turma_atual ON matricula_turma (matricula_id) WHERE saida_em IS NULL;
CREATE INDEX ix_matricula_turma_turma ON matricula_turma (turma_id) WHERE saida_em IS NULL;

-- =====================================================================
-- 8. AULAS E AVALIAÇÕES
-- =====================================================================

CREATE TABLE aula_teorica (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id     uuid         NOT NULL REFERENCES escola(id),
  turma_id      uuid         NOT NULL REFERENCES turma(id),
  instrutor_id  uuid         NOT NULL REFERENCES instrutor(id),
  modulo_id     uuid         REFERENCES curriculo_modulo(id) ON DELETE SET NULL,
  data          date         NOT NULL,
  hora_inicio   time         NOT NULL,
  hora_fim      time         NOT NULL,
  tema          varchar(200),
  sala          varchar(100),
  estado        varchar(10)  NOT NULL DEFAULT 'AGENDADA',
  observacoes   text,
  criado_por    uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  atualizado_em timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_aula_teorica_estado CHECK (estado IN ('AGENDADA','REALIZADA','CANCELADA')),
  CONSTRAINT ck_aula_teorica_horas  CHECK (hora_fim > hora_inicio)
);
CREATE INDEX ix_aula_teorica_turma ON aula_teorica (escola_id, turma_id, data);
CREATE INDEX ix_aula_teorica_data  ON aula_teorica (escola_id, data);

CREATE TABLE presenca (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id        uuid         NOT NULL REFERENCES escola(id),
  aula_teorica_id  uuid         NOT NULL REFERENCES aula_teorica(id) ON DELETE CASCADE,
  matricula_id     uuid         NOT NULL REFERENCES matricula(id),
  estado           varchar(12)  NOT NULL,
  observacao       varchar(300),
  registado_por    uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  registado_em     timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_presenca_estado CHECK (estado IN ('PRESENTE','FALTA','JUSTIFICADA','ATRASO')),
  CONSTRAINT uq_presenca UNIQUE (aula_teorica_id, matricula_id)
);
CREATE INDEX ix_presenca_matricula ON presenca (matricula_id);

-- Aula prática: individual (estudante + instrutor + viatura + período).
-- As restrições EXCLUDE impedem, ao nível da BD, sobreposição de horários do
-- mesmo instrutor, da mesma viatura e da mesma matrícula (aulas não canceladas).
-- A violação é o erro SQLSTATE 23P01 -> a API responde 409 CONFLITO_AGENDA.
CREATE TABLE aula_pratica (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id           uuid         NOT NULL REFERENCES escola(id),
  filial_id           uuid         NOT NULL REFERENCES filial(id),
  matricula_id        uuid         NOT NULL REFERENCES matricula(id),
  instrutor_id        uuid         NOT NULL REFERENCES instrutor(id),
  veiculo_id          uuid         NOT NULL REFERENCES veiculo(id),
  inicio              timestamptz  NOT NULL,
  fim                 timestamptz  NOT NULL,
  tipo                varchar(15)  NOT NULL DEFAULT 'NORMAL',
  estado              varchar(10)  NOT NULL DEFAULT 'AGENDADA',
  ponto_partida       varchar(200),
  km_inicial          integer,
  km_final            integer,
  observacoes         text,
  cancelado_em        timestamptz,
  cancelado_por       uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  motivo_cancelamento varchar(300),
  criado_por          uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em           timestamptz  NOT NULL DEFAULT now(),
  atualizado_em       timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_aula_pratica_tipo    CHECK (tipo IN ('NORMAL','SIMULACRO_EXAME')),
  CONSTRAINT ck_aula_pratica_estado  CHECK (estado IN ('AGENDADA','REALIZADA','CANCELADA','FALTOU')),
  CONSTRAINT ck_aula_pratica_periodo CHECK (fim > inicio),
  CONSTRAINT ck_aula_pratica_km      CHECK (km_inicial IS NULL OR km_final IS NULL OR km_final >= km_inicial),
  CONSTRAINT ck_aula_pratica_cancel  CHECK (estado <> 'CANCELADA' OR cancelado_em IS NOT NULL),
  CONSTRAINT ex_aula_pratica_instrutor EXCLUDE USING gist
    (instrutor_id WITH =, tstzrange(inicio, fim, '[)') WITH &&) WHERE (estado <> 'CANCELADA'),
  CONSTRAINT ex_aula_pratica_veiculo EXCLUDE USING gist
    (veiculo_id WITH =, tstzrange(inicio, fim, '[)') WITH &&) WHERE (estado <> 'CANCELADA'),
  CONSTRAINT ex_aula_pratica_matricula EXCLUDE USING gist
    (matricula_id WITH =, tstzrange(inicio, fim, '[)') WITH &&) WHERE (estado <> 'CANCELADA')
);
CREATE INDEX ix_aula_pratica_escola_inicio ON aula_pratica (escola_id, inicio);
CREATE INDEX ix_aula_pratica_filial_inicio ON aula_pratica (escola_id, filial_id, inicio);

CREATE TABLE avaliacao (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id      uuid         NOT NULL REFERENCES escola(id),
  matricula_id   uuid         NOT NULL REFERENCES matricula(id),
  aula_pratica_id uuid        REFERENCES aula_pratica(id) ON DELETE SET NULL,
  modulo_id      uuid         REFERENCES curriculo_modulo(id) ON DELETE SET NULL,
  avaliador_id   uuid         REFERENCES instrutor(id) ON DELETE SET NULL,
  tipo           varchar(20)  NOT NULL,
  data_avaliacao date         NOT NULL DEFAULT CURRENT_DATE,
  nota           numeric(5,2),
  nota_maxima    numeric(5,2) NOT NULL DEFAULT 20,
  resultado      varchar(10),
  observacoes    text,
  criado_por     uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em      timestamptz  NOT NULL DEFAULT now(),
  atualizado_em  timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_avaliacao_tipo      CHECK (tipo IN ('AULA_PRATICA','SIMULACRO_TEORICO','SIMULACRO_PRATICO','PROVA_INTERNA')),
  CONSTRAINT ck_avaliacao_resultado CHECK (resultado IS NULL OR resultado IN ('APTO','NAO_APTO')),
  CONSTRAINT ck_avaliacao_notas     CHECK (nota_maxima > 0 AND (nota IS NULL OR (nota >= 0 AND nota <= nota_maxima)))
);
CREATE INDEX ix_avaliacao_matricula ON avaliacao (escola_id, matricula_id, data_avaliacao DESC);

-- =====================================================================
-- 9. FINANCEIRO
-- =====================================================================

-- Cobrança = valor a receber (prestação do pacote, taxa de exame, aula extra...).
-- O estado de pagamento (PENDENTE/PARCIAL/PAGA/EM_ATRASO) é DERIVADO: ver vw_cobranca.
CREATE TABLE cobranca (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id        uuid          NOT NULL REFERENCES escola(id),
  filial_id        uuid          NOT NULL REFERENCES filial(id),
  estudante_id     uuid          NOT NULL REFERENCES estudante(id),
  matricula_id     uuid          REFERENCES matricula(id),
  tipo             varchar(12)   NOT NULL,
  descricao        varchar(250)  NOT NULL,
  numero_prestacao smallint,
  total_prestacoes smallint,
  valor            numeric(14,2) NOT NULL,
  data_vencimento  date          NOT NULL,
  estado           varchar(8)    NOT NULL DEFAULT 'ABERTA',
  anulada_em       timestamptz,
  anulada_por      uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  motivo_anulacao  varchar(300),
  criado_por       uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em        timestamptz   NOT NULL DEFAULT now(),
  atualizado_em    timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_cobranca_tipo   CHECK (tipo IN ('PACOTE','TAXA_EXAME','AULA_EXTRA','MATERIAL','SEGUNDA_VIA','OUTRO')),
  CONSTRAINT ck_cobranca_estado CHECK (estado IN ('ABERTA','ANULADA')),
  CONSTRAINT ck_cobranca_valor  CHECK (valor > 0),
  CONSTRAINT ck_cobranca_prestacao CHECK (
    (numero_prestacao IS NULL AND total_prestacoes IS NULL)
    OR (numero_prestacao IS NOT NULL AND total_prestacoes IS NOT NULL AND numero_prestacao BETWEEN 1 AND total_prestacoes)
  ),
  CONSTRAINT ck_cobranca_anulacao CHECK (estado = 'ABERTA' OR anulada_em IS NOT NULL)
);
CREATE INDEX ix_cobranca_estudante   ON cobranca (escola_id, estudante_id);
CREATE INDEX ix_cobranca_matricula   ON cobranca (matricula_id) WHERE matricula_id IS NOT NULL;
CREATE INDEX ix_cobranca_vencimento  ON cobranca (escola_id, data_vencimento) WHERE estado = 'ABERTA';

-- Pagamento = dinheiro recebido; é repartido por uma ou mais cobranças (alocações).
-- Nunca se apaga: anula-se (estado ANULADO) e deixa de contar nas views.
CREATE TABLE pagamento (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id         uuid          NOT NULL REFERENCES escola(id),
  filial_id         uuid          NOT NULL REFERENCES filial(id),
  estudante_id      uuid          NOT NULL REFERENCES estudante(id),
  numero            varchar(30)   NOT NULL,
  valor_total       numeric(14,2) NOT NULL,
  metodo            varchar(20)   NOT NULL,
  referencia_externa varchar(100),
  data_pagamento    timestamptz   NOT NULL DEFAULT now(),
  comprovativo_key  varchar(400),
  estado            varchar(10)   NOT NULL DEFAULT 'CONFIRMADO',
  recebido_por      uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  anulado_em        timestamptz,
  anulado_por       uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  motivo_anulacao   varchar(300),
  idempotency_key   varchar(80),
  observacoes       varchar(400),
  criado_em         timestamptz   NOT NULL DEFAULT now(),
  atualizado_em     timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_pagamento_valor   CHECK (valor_total > 0),
  CONSTRAINT ck_pagamento_metodo  CHECK (metodo IN ('NUMERARIO','TPA','MULTICAIXA_EXPRESS','TRANSFERENCIA','DEPOSITO','REFERENCIA','OUTRO')),
  CONSTRAINT ck_pagamento_estado  CHECK (estado IN ('CONFIRMADO','ANULADO')),
  CONSTRAINT ck_pagamento_anulacao CHECK (estado = 'CONFIRMADO' OR anulado_em IS NOT NULL)
);
CREATE UNIQUE INDEX ux_pagamento_numero ON pagamento (escola_id, numero);
CREATE UNIQUE INDEX ux_pagamento_idempotencia ON pagamento (escola_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX ix_pagamento_estudante ON pagamento (escola_id, estudante_id);
CREATE INDEX ix_pagamento_data      ON pagamento (escola_id, data_pagamento DESC);

CREATE TABLE pagamento_alocacao (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id   uuid          NOT NULL REFERENCES escola(id),
  pagamento_id uuid         NOT NULL REFERENCES pagamento(id) ON DELETE CASCADE,
  cobranca_id uuid          NOT NULL REFERENCES cobranca(id),
  valor       numeric(14,2) NOT NULL,
  criado_em   timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_alocacao_valor CHECK (valor > 0),
  CONSTRAINT uq_alocacao UNIQUE (pagamento_id, cobranca_id)
);
CREATE INDEX ix_alocacao_cobranca ON pagamento_alocacao (cobranca_id);

CREATE TABLE despesa (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id     uuid          NOT NULL REFERENCES escola(id),
  filial_id     uuid          NOT NULL REFERENCES filial(id),
  veiculo_id    uuid          REFERENCES veiculo(id),
  categoria     varchar(15)   NOT NULL,
  descricao     varchar(250)  NOT NULL,
  valor         numeric(14,2) NOT NULL,
  data_despesa  date          NOT NULL DEFAULT CURRENT_DATE,
  fornecedor    varchar(150),
  comprovativo_key varchar(400),
  criado_por    uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em     timestamptz   NOT NULL DEFAULT now(),
  atualizado_em timestamptz   NOT NULL DEFAULT now(),
  eliminado_em  timestamptz,
  CONSTRAINT ck_despesa_categoria CHECK (categoria IN ('COMBUSTIVEL','MANUTENCAO','SALARIOS','RENDA','IMPOSTOS','MATERIAL','OUTRA')),
  CONSTRAINT ck_despesa_valor     CHECK (valor > 0)
);
CREATE INDEX ix_despesa_data ON despesa (escola_id, data_despesa DESC) WHERE eliminado_em IS NULL;

-- =====================================================================
-- 10. EXAMES E PROCESSO DA CARTA
-- =====================================================================

CREATE TABLE sessao_exame (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id            uuid         NOT NULL REFERENCES escola(id),
  filial_id            uuid         REFERENCES filial(id),
  categoria_id         uuid         NOT NULL REFERENCES categoria_carta(id),
  tipo                 varchar(10)  NOT NULL,
  data_exame           date         NOT NULL,
  hora                 time,
  local                varchar(200),
  entidade_examinadora varchar(150),
  vagas                smallint,
  estado               varchar(10)  NOT NULL DEFAULT 'AGENDADA',
  observacoes          text,
  criado_por           uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em            timestamptz  NOT NULL DEFAULT now(),
  atualizado_em        timestamptz  NOT NULL DEFAULT now(),
  eliminado_em         timestamptz,
  CONSTRAINT ck_sessao_exame_tipo   CHECK (tipo IN ('TEORICO','PRATICO')),
  CONSTRAINT ck_sessao_exame_estado CHECK (estado IN ('AGENDADA','REALIZADA','CANCELADA')),
  CONSTRAINT ck_sessao_exame_vagas  CHECK (vagas IS NULL OR vagas > 0)
);
CREATE INDEX ix_sessao_exame_data ON sessao_exame (escola_id, data_exame DESC) WHERE eliminado_em IS NULL;

CREATE TABLE inscricao_exame (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id        uuid          NOT NULL REFERENCES escola(id),
  sessao_exame_id  uuid          NOT NULL REFERENCES sessao_exame(id),
  matricula_id     uuid          NOT NULL REFERENCES matricula(id),
  cobranca_id      uuid          REFERENCES cobranca(id) ON DELETE SET NULL,
  tentativa        smallint      NOT NULL DEFAULT 1,
  taxa_valor       numeric(14,2) NOT NULL DEFAULT 0,
  estado           varchar(10)   NOT NULL DEFAULT 'INSCRITO',
  resultado        varchar(10)   NOT NULL DEFAULT 'PENDENTE',
  nota             numeric(5,2),
  observacoes      varchar(400),
  registado_por    uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em        timestamptz   NOT NULL DEFAULT now(),
  atualizado_em    timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_inscricao_exame_estado    CHECK (estado IN ('INSCRITO','PRESENTE','FALTOU','CANCELADO')),
  CONSTRAINT ck_inscricao_exame_resultado CHECK (resultado IN ('PENDENTE','APROVADO','REPROVADO')),
  CONSTRAINT ck_inscricao_exame_coerencia CHECK (resultado = 'PENDENTE' OR estado = 'PRESENTE'),
  CONSTRAINT ck_inscricao_exame_tentativa CHECK (tentativa >= 1),
  CONSTRAINT ck_inscricao_exame_taxa      CHECK (taxa_valor >= 0),
  CONSTRAINT uq_inscricao_exame UNIQUE (sessao_exame_id, matricula_id)
);
CREATE INDEX ix_inscricao_exame_matricula ON inscricao_exame (matricula_id);

-- Processo administrativo da carta (depois de aprovado nos exames).
CREATE TABLE processo_carta (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id        uuid         NOT NULL REFERENCES escola(id),
  matricula_id     uuid         NOT NULL UNIQUE REFERENCES matricula(id),
  estado           varchar(15)  NOT NULL DEFAULT 'EM_PREPARACAO',
  numero_processo  varchar(60),
  data_submissao   date,
  data_emissao     date,
  data_entrega     date,
  observacoes      text,
  atualizado_por   uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em        timestamptz  NOT NULL DEFAULT now(),
  atualizado_em    timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_processo_carta_estado CHECK (estado IN ('EM_PREPARACAO','SUBMETIDO','EM_ANALISE','PRONTA','ENTREGUE','REJEITADO'))
);

-- =====================================================================
-- 11. NUMERAÇÃO, DOCUMENTOS EMITIDOS E NOTIFICAÇÕES
-- =====================================================================

-- Séries de numeração por escola/tipo/ano. ano = 0 -> série contínua (sem reinício anual).
CREATE TABLE serie_documental (
  escola_id     uuid        NOT NULL REFERENCES escola(id),
  tipo          varchar(12) NOT NULL,
  ano           smallint    NOT NULL DEFAULT 0,
  prefixo       varchar(20),
  ultimo_numero integer     NOT NULL DEFAULT 0,
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (escola_id, tipo, ano),
  CONSTRAINT ck_serie_tipo CHECK (tipo IN ('ESTUDANTE','MATRICULA','RECIBO','DECLARACAO','CONTRATO','CERTIFICADO','EXTRATO')),
  CONSTRAINT ck_serie_ultimo CHECK (ultimo_numero >= 0)
);

-- Devolve o próximo número da série, de forma atómica e sem lacunas concorrentes.
-- Usar dentro da transação que cria o registo (se a transação falhar, o número volta).
CREATE OR REPLACE FUNCTION fn_proximo_numero(p_escola_id uuid, p_tipo varchar, p_ano smallint DEFAULT 0)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_numero integer;
BEGIN
  INSERT INTO serie_documental (escola_id, tipo, ano, ultimo_numero)
  VALUES (p_escola_id, p_tipo, p_ano, 1)
  ON CONFLICT (escola_id, tipo, ano)
  DO UPDATE SET ultimo_numero = serie_documental.ultimo_numero + 1, atualizado_em = now()
  RETURNING ultimo_numero INTO v_numero;
  RETURN v_numero;
END;
$$;

-- Registo dos documentos oficiais gerados pelo backend (o ficheiro fica no storage).
CREATE TABLE documento_emitido (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id       uuid         NOT NULL REFERENCES escola(id),
  tipo            varchar(25)  NOT NULL,
  numero          varchar(40),
  estudante_id    uuid         REFERENCES estudante(id),
  matricula_id    uuid         REFERENCES matricula(id),
  pagamento_id    uuid         REFERENCES pagamento(id),
  ficheiro_key    varchar(400) NOT NULL,
  hash_sha256     varchar(64)  NOT NULL,
  gerado_por      uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  gerado_em       timestamptz  NOT NULL DEFAULT now(),
  anulado_em      timestamptz,
  anulado_por     uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  motivo_anulacao varchar(300),
  CONSTRAINT ck_documento_emitido_tipo CHECK (tipo IN (
    'RECIBO','DECLARACAO_MATRICULA','CONTRATO_FORMACAO','FICHA_ESTUDANTE',
    'EXTRATO_FINANCEIRO','CERTIFICADO_CONCLUSAO','DECLARACAO_FREQUENCIA'))
);
CREATE UNIQUE INDEX ux_documento_emitido_numero ON documento_emitido (escola_id, tipo, numero) WHERE numero IS NOT NULL;
CREATE INDEX ix_documento_emitido_estudante ON documento_emitido (escola_id, estudante_id);

CREATE TABLE notificacao (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escola_id     uuid         NOT NULL REFERENCES escola(id),
  utilizador_id uuid         REFERENCES utilizador(id) ON DELETE CASCADE,
  estudante_id  uuid         REFERENCES estudante(id) ON DELETE CASCADE,
  canal         varchar(10)  NOT NULL DEFAULT 'INTERNA',
  assunto       varchar(200),
  mensagem      text         NOT NULL,
  estado        varchar(10)  NOT NULL DEFAULT 'PENDENTE',
  agendada_para timestamptz,
  enviada_em    timestamptz,
  lida_em       timestamptz,
  erro          varchar(500),
  criado_por    uuid REFERENCES utilizador(id) ON DELETE SET NULL,
  criado_em     timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT ck_notificacao_canal   CHECK (canal IN ('INTERNA','SMS','EMAIL','WHATSAPP')),
  CONSTRAINT ck_notificacao_estado  CHECK (estado IN ('PENDENTE','ENVIADA','FALHOU','LIDA')),
  CONSTRAINT ck_notificacao_destino CHECK (utilizador_id IS NOT NULL OR estudante_id IS NOT NULL)
);
CREATE INDEX ix_notificacao_utilizador ON notificacao (utilizador_id, criado_em DESC) WHERE utilizador_id IS NOT NULL;
CREATE INDEX ix_notificacao_pendentes  ON notificacao (agendada_para) WHERE estado = 'PENDENTE';

-- =====================================================================
-- 12. VIEWS (mapear como @ViewEntity; só leitura)
-- =====================================================================

-- Cobranças com valor pago, saldo e situação derivada.
-- Situação: ANULADA | PAGA | EM_ATRASO | PARCIAL | PENDENTE (por esta ordem de prioridade).
CREATE VIEW vw_cobranca AS
SELECT
  c.id, c.escola_id, c.filial_id, c.estudante_id, c.matricula_id, c.tipo, c.descricao,
  c.numero_prestacao, c.total_prestacoes, c.valor, c.data_vencimento, c.estado,
  COALESCE(p.valor_pago, 0)::numeric(14,2)              AS valor_pago,
  (c.valor - COALESCE(p.valor_pago, 0))::numeric(14,2)  AS saldo,
  CASE
    WHEN c.estado = 'ANULADA'                  THEN 'ANULADA'
    WHEN COALESCE(p.valor_pago, 0) >= c.valor  THEN 'PAGA'
    WHEN c.data_vencimento < f_hoje()          THEN 'EM_ATRASO'
    WHEN COALESCE(p.valor_pago, 0) > 0         THEN 'PARCIAL'
    ELSE 'PENDENTE'
  END AS situacao
FROM cobranca c
LEFT JOIN LATERAL (
  SELECT SUM(a.valor) AS valor_pago
  FROM pagamento_alocacao a
  JOIN pagamento pg ON pg.id = a.pagamento_id AND pg.estado = 'CONFIRMADO'
  WHERE a.cobranca_id = c.id
) p ON true;

-- Ocupação e andamento das turmas.
CREATE VIEW vw_turma_resumo AS
SELECT
  t.id AS turma_id, t.escola_id, t.ano, t.estado, t.vagas,
  COALESCE(m.ocupadas, 0)::int                        AS vagas_ocupadas,
  (t.vagas - COALESCE(m.ocupadas, 0))::int            AS vagas_livres,
  COALESCE(a.total, 0)::int                           AS aulas_total,
  COALESCE(a.realizadas, 0)::int                      AS aulas_realizadas
FROM turma t
LEFT JOIN (
  SELECT turma_id, COUNT(*) AS ocupadas
  FROM matricula_turma WHERE saida_em IS NULL GROUP BY turma_id
) m ON m.turma_id = t.id
LEFT JOIN (
  SELECT turma_id,
         COUNT(*) FILTER (WHERE estado <> 'CANCELADA') AS total,
         COUNT(*) FILTER (WHERE estado = 'REALIZADA')  AS realizadas
  FROM aula_teorica GROUP BY turma_id
) a ON a.turma_id = t.id
WHERE t.eliminado_em IS NULL;

-- Progresso por matrícula (separador "Progresso" do estudante). Tudo derivado.
CREATE VIEW vw_progresso_matricula AS
SELECT
  m.id AS matricula_id, m.escola_id, m.estudante_id, m.categoria_id, m.estado,
  COALESCE(cu.aulas_teoricas_minimas, 0)   AS aulas_teoricas_minimas,
  COALESCE(cu.aulas_praticas_minimas, 0)   AS aulas_praticas_minimas,
  COALESCE(t.frequentadas, 0)::int         AS aulas_teoricas_frequentadas,
  COALESCE(p.realizadas, 0)::int           AS aulas_praticas_realizadas,
  COALESCE(p.agendadas, 0)::int            AS aulas_praticas_agendadas,
  CASE WHEN COALESCE(cu.aulas_teoricas_minimas, 0) = 0 THEN NULL
       ELSE LEAST(100, ROUND(100.0 * COALESCE(t.frequentadas, 0) / cu.aulas_teoricas_minimas))::int END AS percentual_teorico,
  CASE WHEN COALESCE(cu.aulas_praticas_minimas, 0) = 0 THEN NULL
       ELSE LEAST(100, ROUND(100.0 * COALESCE(p.realizadas, 0) / cu.aulas_praticas_minimas))::int END AS percentual_pratico,
  ROUND(av.media, 2)                       AS media_notas,
  COALESCE(et.aprovado, false)             AS exame_teorico_aprovado,
  COALESCE(ep.aprovado, false)             AS exame_pratico_aprovado,
  pc.estado                                AS processo_carta_estado,
  (m.preco_acordado - m.desconto)::numeric(14,2)   AS valor_liquido,
  COALESCE(f.pago, 0)::numeric(14,2)               AS valor_pago,
  COALESCE(f.em_aberto, 0)::numeric(14,2)          AS valor_em_aberto,
  COALESCE(f.em_atraso, 0)::numeric(14,2)          AS valor_em_atraso
FROM matricula m
LEFT JOIN curriculo cu ON cu.id = m.curriculo_id
LEFT JOIN (
  SELECT pr.matricula_id, COUNT(*) AS frequentadas
  FROM presenca pr
  JOIN aula_teorica at2 ON at2.id = pr.aula_teorica_id AND at2.estado = 'REALIZADA'
  WHERE pr.estado IN ('PRESENTE','ATRASO')
  GROUP BY pr.matricula_id
) t ON t.matricula_id = m.id
LEFT JOIN (
  SELECT matricula_id,
         COUNT(*) FILTER (WHERE estado = 'REALIZADA') AS realizadas,
         COUNT(*) FILTER (WHERE estado = 'AGENDADA')  AS agendadas
  FROM aula_pratica GROUP BY matricula_id
) p ON p.matricula_id = m.id
LEFT JOIN (
  SELECT matricula_id, AVG(nota / nota_maxima * 20) AS media
  FROM avaliacao WHERE nota IS NOT NULL GROUP BY matricula_id
) av ON av.matricula_id = m.id
LEFT JOIN (
  SELECT i.matricula_id, BOOL_OR(i.resultado = 'APROVADO') AS aprovado
  FROM inscricao_exame i JOIN sessao_exame s ON s.id = i.sessao_exame_id AND s.tipo = 'TEORICO'
  GROUP BY i.matricula_id
) et ON et.matricula_id = m.id
LEFT JOIN (
  SELECT i.matricula_id, BOOL_OR(i.resultado = 'APROVADO') AS aprovado
  FROM inscricao_exame i JOIN sessao_exame s ON s.id = i.sessao_exame_id AND s.tipo = 'PRATICO'
  GROUP BY i.matricula_id
) ep ON ep.matricula_id = m.id
LEFT JOIN processo_carta pc ON pc.matricula_id = m.id
LEFT JOIN (
  SELECT matricula_id,
         SUM(valor_pago) FILTER (WHERE situacao <> 'ANULADA') AS pago,
         SUM(saldo)      FILTER (WHERE situacao <> 'ANULADA') AS em_aberto,
         SUM(saldo)      FILTER (WHERE situacao = 'EM_ATRASO') AS em_atraso
  FROM vw_cobranca WHERE matricula_id IS NOT NULL GROUP BY matricula_id
) f ON f.matricula_id = m.id
WHERE m.eliminado_em IS NULL;

-- Listagem de estudantes: mostra a matrícula "principal" (viva mais recente, senão a mais recente).
-- Filtros por turma/categoria/ano nesta view referem-se a essa matrícula principal.
CREATE VIEW vw_estudante_listagem AS
SELECT
  e.id, e.escola_id, e.filial_id, e.numero, e.nome_completo, e.doc_tipo, e.doc_numero,
  e.telefone, e.email, e.estado, e.foto_key, e.criado_em,
  mp.matricula_id, mp.matricula_codigo, mp.matricula_estado,
  mp.categoria_id, mp.categoria_codigo,
  mp.turma_id, mp.turma_codigo, mp.turma_ano,
  COALESCE(fa.em_atraso, 0)::numeric(14,2) AS valor_em_atraso
FROM estudante e
LEFT JOIN LATERAL (
  SELECT m.id AS matricula_id, m.codigo AS matricula_codigo, m.estado AS matricula_estado,
         m.categoria_id, cc.codigo AS categoria_codigo,
         t.id AS turma_id, t.codigo AS turma_codigo, t.ano AS turma_ano
  FROM matricula m
  JOIN categoria_carta cc ON cc.id = m.categoria_id
  LEFT JOIN matricula_turma mt ON mt.matricula_id = m.id AND mt.saida_em IS NULL
  LEFT JOIN turma t ON t.id = mt.turma_id
  WHERE m.estudante_id = e.id AND m.eliminado_em IS NULL
  ORDER BY (m.estado IN ('PENDENTE','ATIVA','SUSPENSA')) DESC, m.data_matricula DESC, m.criado_em DESC
  LIMIT 1
) mp ON true
LEFT JOIN LATERAL (
  SELECT SUM(c.saldo) AS em_atraso
  FROM vw_cobranca c
  WHERE c.estudante_id = e.id AND c.situacao = 'EM_ATRASO'
) fa ON true
WHERE e.eliminado_em IS NULL;

-- =====================================================================
-- 13. PROVISIONAMENTO DE UMA ESCOLA NOVA
-- =====================================================================

-- Clona os perfis modelo para a escola. Idempotente: só cria perfis em falta e só
-- preenche permissões de perfis que ainda não têm nenhuma (não repõe permissões removidas).
CREATE OR REPLACE FUNCTION fn_provisionar_perfis_escola(p_escola_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO perfil (escola_id, chave, nome, descricao, e_sistema, protegido)
  SELECT p_escola_id, pm.chave, pm.nome, pm.descricao, true, pm.protegido
  FROM perfil_modelo pm
  WHERE NOT EXISTS (
    SELECT 1 FROM perfil pf
    WHERE pf.escola_id = p_escola_id AND pf.chave = pm.chave AND pf.eliminado_em IS NULL
  );

  INSERT INTO perfil_permissao (perfil_id, permissao_id, escopo)
  SELECT pf.id, pmp.permissao_id, pmp.escopo
  FROM perfil pf
  JOIN perfil_modelo_permissao pmp ON pmp.perfil_modelo_chave = pf.chave
  WHERE pf.escola_id = p_escola_id
    AND pf.e_sistema
    AND pf.eliminado_em IS NULL
    AND NOT EXISTS (SELECT 1 FROM perfil_permissao x WHERE x.perfil_id = pf.id)
  ON CONFLICT (perfil_id, permissao_id) DO NOTHING;
END;
$$;

-- Prepara tudo o que uma escola precisa antes do onboarding: identidade e
-- configuração com valores por omissão, perfis de sistema e tipos de documento.
-- Chamar na mesma transação que cria a escola. A filial principal e o primeiro
-- utilizador ADMINISTRADOR são criados pela API (EscolasService.provisionar).
CREATE OR REPLACE FUNCTION fn_provisionar_escola(p_escola_id uuid) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO escola_identidade (escola_id)    VALUES (p_escola_id) ON CONFLICT (escola_id) DO NOTHING;
  INSERT INTO escola_configuracao (escola_id)  VALUES (p_escola_id) ON CONFLICT (escola_id) DO NOTHING;

  PERFORM fn_provisionar_perfis_escola(p_escola_id);

  -- Valores iniciais EDITÁVEIS (confirmar com cada escola quais documentos são exigidos).
  INSERT INTO tipo_documento (escola_id, aplica_a, codigo, nome, obrigatorio, tem_validade, sensivel, ordem)
  SELECT p_escola_id, d.aplica_a, d.codigo, d.nome, d.obrigatorio, d.tem_validade, d.sensivel, d.ordem
  FROM (VALUES
    ('ESTUDANTE', 'BI',                  'Bilhete de Identidade',      true,  true,  false, 1),
    ('ESTUDANTE', 'FOTOGRAFIA',          'Fotografia tipo passe',      true,  false, false, 2),
    ('ESTUDANTE', 'FICHA_MEDICA',        'Ficha / atestado médico',    true,  true,  true,  3),
    ('ESTUDANTE', 'CONTRATO_ASSINADO',   'Contrato assinado',          false, false, false, 4),
    ('ESTUDANTE', 'COMPROVATIVO_PAGAMENTO', 'Comprovativo de pagamento', false, false, false, 5),
    ('ESTUDANTE', 'OUTRO',               'Outro documento',            false, false, false, 99),
    ('INSTRUTOR', 'BI',                  'Bilhete de Identidade',      true,  true,  false, 1),
    ('INSTRUTOR', 'CARTA_CONDUCAO',      'Carta de condução',          true,  true,  false, 2),
    ('INSTRUTOR', 'LICENCA_INSTRUTOR',   'Licença de instrutor',       true,  true,  false, 3),
    ('INSTRUTOR', 'OUTRO',               'Outro documento',            false, false, false, 99),
    ('VEICULO',   'LIVRETE',             'Livrete',                    true,  false, false, 1),
    ('VEICULO',   'SEGURO',              'Seguro',                     true,  true,  false, 2),
    ('VEICULO',   'INSPECAO',            'Inspeção periódica',        false, true,  false, 3),
    ('VEICULO',   'OUTRO',               'Outro documento',            false, false, false, 99)
  ) AS d(aplica_a, codigo, nome, obrigatorio, tem_validade, sensivel, ordem)
  ON CONFLICT (escola_id, aplica_a, codigo) DO NOTHING;
END;
$$;

-- =====================================================================
-- 14. TRIGGERS: atualizado_em
-- =====================================================================
CREATE TRIGGER trg_escola_atualizado_em BEFORE UPDATE ON escola
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_escola_identidade_atualizado_em BEFORE UPDATE ON escola_identidade
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_escola_configuracao_atualizado_em BEFORE UPDATE ON escola_configuracao
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_plano_atualizado_em BEFORE UPDATE ON plano
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_subscricao_atualizado_em BEFORE UPDATE ON subscricao
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_filial_atualizado_em BEFORE UPDATE ON filial
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_utilizador_atualizado_em BEFORE UPDATE ON utilizador
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_permissao_atualizado_em BEFORE UPDATE ON permissao
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_perfil_atualizado_em BEFORE UPDATE ON perfil
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_categoria_carta_atualizado_em BEFORE UPDATE ON categoria_carta
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_curriculo_atualizado_em BEFORE UPDATE ON curriculo
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_curriculo_modulo_atualizado_em BEFORE UPDATE ON curriculo_modulo
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_pacote_atualizado_em BEFORE UPDATE ON pacote
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_estudante_atualizado_em BEFORE UPDATE ON estudante
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_instrutor_atualizado_em BEFORE UPDATE ON instrutor
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_funcionario_atualizado_em BEFORE UPDATE ON funcionario
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_veiculo_atualizado_em BEFORE UPDATE ON veiculo
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_veiculo_manutencao_atualizado_em BEFORE UPDATE ON veiculo_manutencao
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_tipo_documento_atualizado_em BEFORE UPDATE ON tipo_documento
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_anexo_atualizado_em BEFORE UPDATE ON anexo
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_turma_atualizado_em BEFORE UPDATE ON turma
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_matricula_atualizado_em BEFORE UPDATE ON matricula
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_aula_teorica_atualizado_em BEFORE UPDATE ON aula_teorica
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_aula_pratica_atualizado_em BEFORE UPDATE ON aula_pratica
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_avaliacao_atualizado_em BEFORE UPDATE ON avaliacao
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_cobranca_atualizado_em BEFORE UPDATE ON cobranca
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_pagamento_atualizado_em BEFORE UPDATE ON pagamento
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_despesa_atualizado_em BEFORE UPDATE ON despesa
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_sessao_exame_atualizado_em BEFORE UPDATE ON sessao_exame
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_inscricao_exame_atualizado_em BEFORE UPDATE ON inscricao_exame
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_processo_carta_atualizado_em BEFORE UPDATE ON processo_carta
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();
CREATE TRIGGER trg_serie_documental_atualizado_em BEFORE UPDATE ON serie_documental
  FOR EACH ROW EXECUTE FUNCTION trg_set_atualizado_em();

-- =====================================================================
-- 15. DADOS INICIAIS (idempotentes)
-- =====================================================================

-- Catálogo de permissões (105). O código da API sincroniza esta tabela no arranque
-- (upsert por `codigo`). Mantê-lo igual ao catálogo em src/modules/acesso/permissoes.catalogo.ts.
INSERT INTO permissao (codigo, modulo, descricao, sensivel) VALUES
  ('utilizador:ver', 'acesso', 'Ver utilizadores da escola', false),
  ('utilizador:criar', 'acesso', 'Criar utilizadores', false),
  ('utilizador:editar', 'acesso', 'Editar utilizadores e atribuir perfis', false),
  ('utilizador:desativar', 'acesso', 'Desativar e reativar utilizadores', false),
  ('utilizador:redefinir_senha', 'acesso', 'Redefinir a senha de outro utilizador', true),
  ('perfil:ver', 'acesso', 'Ver perfis e as suas permissões', false),
  ('perfil:criar', 'acesso', 'Criar perfis personalizados', false),
  ('perfil:editar', 'acesso', 'Editar perfis e as suas permissões', false),
  ('perfil:eliminar', 'acesso', 'Eliminar perfis sem utilizadores', false),
  ('permissao:ver', 'acesso', 'Ver o catálogo de permissões', false),
  ('permissao:atribuir', 'acesso', 'Atribuir permissões individuais (ALLOW/DENY) a utilizadores', true),
  ('auditoria:ver', 'acesso', 'Consultar o registo de auditoria', true),
  ('escola:ver', 'escola', 'Ver dados da escola', false),
  ('escola:editar', 'escola', 'Editar dados da escola', false),
  ('escola_identidade:editar', 'escola', 'Editar identidade visual (logótipo, cores, cabeçalho de documentos)', false),
  ('escola_configuracao:editar', 'escola', 'Editar regras operacionais (durações, janelas de aulas, notas)', false),
  ('filial:ver', 'escola', 'Ver filiais', false),
  ('filial:criar', 'escola', 'Criar filiais', false),
  ('filial:editar', 'escola', 'Editar filiais', false),
  ('filial:desativar', 'escola', 'Desativar filiais', false),
  ('subscricao:ver', 'escola', 'Ver plano e subscrição da escola', false),
  ('estudante:ver', 'estudantes', 'Ver estudantes e o seu ecrã de detalhe', false),
  ('estudante:criar', 'estudantes', 'Registar estudantes', false),
  ('estudante:editar', 'estudantes', 'Editar dados do estudante', false),
  ('estudante:eliminar', 'estudantes', 'Eliminar estudantes (soft delete)', true),
  ('estudante:exportar', 'estudantes', 'Exportar listagens de estudantes (PDF/Excel)', false),
  ('estudante_acesso:gerir', 'estudantes', 'Criar/gerir conta de acesso do estudante (portal futuro)', true),
  ('anexo:ver', 'documentos', 'Ver e descarregar anexos não sensíveis', false),
  ('anexo:carregar', 'documentos', 'Carregar anexos', false),
  ('anexo:validar', 'documentos', 'Validar ou rejeitar anexos', false),
  ('anexo:eliminar', 'documentos', 'Eliminar anexos', false),
  ('anexo_sensivel:ver', 'documentos', 'Ver anexos sensíveis (ex.: ficha médica)', true),
  ('tipo_documento:ver', 'documentos', 'Ver tipos de documento', false),
  ('tipo_documento:gerir', 'documentos', 'Criar e editar tipos de documento', false),
  ('documento:gerar', 'documentos', 'Gerar documentos (recibo, declaração, contrato, ficha...)', false),
  ('documento:ver', 'documentos', 'Ver e descarregar documentos emitidos', false),
  ('documento:anular', 'documentos', 'Anular documentos emitidos', true),
  ('categoria:ver', 'formacao', 'Ver categorias de carta', false),
  ('categoria:gerir', 'formacao', 'Criar e editar categorias de carta', false),
  ('curriculo:ver', 'formacao', 'Ver currículos e módulos', false),
  ('curriculo:gerir', 'formacao', 'Criar e editar currículos e módulos', false),
  ('pacote:ver', 'formacao', 'Ver pacotes e preços', false),
  ('pacote:gerir', 'formacao', 'Criar e editar pacotes e preços', false),
  ('turma:ver', 'turmas', 'Ver turmas', false),
  ('turma:criar', 'turmas', 'Criar turmas', false),
  ('turma:editar', 'turmas', 'Editar turmas e mudar o seu estado', false),
  ('turma:cancelar', 'turmas', 'Cancelar turmas', false),
  ('turma:exportar', 'turmas', 'Exportar turmas e listas de estudantes (PDF/Excel)', false),
  ('turma_estudante:gerir', 'turmas', 'Inscrever, remover e mudar estudantes de turma', false),
  ('matricula:ver', 'matriculas', 'Ver matrículas', false),
  ('matricula:criar', 'matriculas', 'Criar matrículas', false),
  ('matricula:editar', 'matriculas', 'Editar matrículas', false),
  ('matricula:cancelar', 'matriculas', 'Cancelar matrículas e registar desistências', true),
  ('matricula:suspender', 'matriculas', 'Suspender matrículas', false),
  ('matricula:reativar', 'matriculas', 'Reativar matrículas suspensas', false),
  ('aula_teorica:ver', 'aulas_teoricas', 'Ver aulas teóricas', false),
  ('aula_teorica:criar', 'aulas_teoricas', 'Criar aulas teóricas', false),
  ('aula_teorica:editar', 'aulas_teoricas', 'Editar aulas teóricas e marcá-las como realizadas', false),
  ('aula_teorica:cancelar', 'aulas_teoricas', 'Cancelar aulas teóricas', false),
  ('presenca:ver', 'aulas_teoricas', 'Ver presenças', false),
  ('presenca:registar', 'aulas_teoricas', 'Registar presenças', false),
  ('aula_pratica:ver', 'aulas_praticas', 'Ver agenda de aulas práticas', false),
  ('aula_pratica:agendar', 'aulas_praticas', 'Agendar aulas práticas', false),
  ('aula_pratica:remarcar', 'aulas_praticas', 'Remarcar aulas práticas', false),
  ('aula_pratica:cancelar', 'aulas_praticas', 'Cancelar aulas práticas', false),
  ('aula_pratica:registar', 'aulas_praticas', 'Registar realização, falta e quilometragem', false),
  ('avaliacao:ver', 'aulas_praticas', 'Ver avaliações', false),
  ('avaliacao:registar', 'aulas_praticas', 'Registar avaliações', false),
  ('instrutor:ver', 'pessoal', 'Ver instrutores/professores', false),
  ('instrutor:criar', 'pessoal', 'Criar instrutores/professores', false),
  ('instrutor:editar', 'pessoal', 'Editar instrutores/professores', false),
  ('instrutor:desativar', 'pessoal', 'Desativar instrutores/professores', false),
  ('funcionario:ver', 'pessoal', 'Ver funcionários', false),
  ('funcionario:criar', 'pessoal', 'Criar funcionários', false),
  ('funcionario:editar', 'pessoal', 'Editar funcionários', false),
  ('funcionario:desativar', 'pessoal', 'Desativar funcionários', false),
  ('exame:ver', 'exames', 'Ver sessões e inscrições de exame', false),
  ('exame:gerir', 'exames', 'Criar e editar sessões de exame', false),
  ('exame_inscricao:criar', 'exames', 'Inscrever matrículas em exames', false),
  ('exame_inscricao:resultado', 'exames', 'Registar presença e resultado de exame', false),
  ('processo_carta:ver', 'exames', 'Ver processo da carta', false),
  ('processo_carta:gerir', 'exames', 'Gerir o processo da carta', false),
  ('veiculo:ver', 'frota', 'Ver veículos e abastecimentos', false),
  ('veiculo:criar', 'frota', 'Criar veículos', false),
  ('veiculo:editar', 'frota', 'Editar veículos', false),
  ('veiculo:desativar', 'frota', 'Desativar veículos', false),
  ('manutencao:ver', 'frota', 'Ver manutenções', false),
  ('manutencao:registar', 'frota', 'Registar manutenções', false),
  ('abastecimento:registar', 'frota', 'Registar abastecimentos', false),
  ('cobranca:ver', 'financeiro', 'Ver cobranças e conta corrente', false),
  ('cobranca:criar', 'financeiro', 'Criar cobranças e planos de prestações', false),
  ('cobranca:anular', 'financeiro', 'Anular cobranças', true),
  ('pagamento:ver', 'financeiro', 'Ver pagamentos', false),
  ('pagamento:registar', 'financeiro', 'Registar pagamentos', false),
  ('pagamento:anular', 'financeiro', 'Anular pagamentos', true),
  ('desconto:aplicar', 'financeiro', 'Aplicar descontos', true),
  ('despesa:ver', 'financeiro', 'Ver despesas', false),
  ('despesa:registar', 'financeiro', 'Registar despesas', false),
  ('despesa:eliminar', 'financeiro', 'Eliminar despesas', true),
  ('financeiro_relatorio:ver', 'financeiro', 'Ver relatórios financeiros', true),
  ('relatorio:ver', 'relatorios', 'Ver relatórios operacionais', false),
  ('relatorio:exportar', 'relatorios', 'Exportar relatórios (PDF/Excel)', false),
  ('dashboard:ver', 'relatorios', 'Ver o painel inicial', false),
  ('notificacao:ver', 'notificacoes', 'Ver notificações', false),
  ('notificacao:enviar', 'notificacoes', 'Enviar notificações a estudantes e utilizadores', false)
ON CONFLICT (codigo) DO UPDATE SET modulo = EXCLUDED.modulo, descricao = EXCLUDED.descricao, sensivel = EXCLUDED.sensivel;

-- Perfis modelo (clonados para cada escola por fn_provisionar_escola)
INSERT INTO perfil_modelo (chave, nome, descricao, protegido, ordem) VALUES
  ('ADMINISTRADOR', 'Administrador', 'Proprietário/diretor. Acesso total à escola, incluindo utilizadores, perfis e configurações.', true, 1),
  ('GESTOR_FILIAL', 'Gestor de Filial', 'Gere a operação e as finanças da(s) sua(s) filial(is). Não gere perfis nem configurações da escola.', false, 2),
  ('SECRETARIA', 'Secretaria', 'Receção: estudantes, matrículas, agendamentos e recebimento de pagamentos.', false, 3),
  ('FINANCEIRO', 'Financeiro', 'Cobranças, pagamentos, anulações, descontos, despesas e relatórios financeiros.', false, 4),
  ('COORDENADOR_PEDAGOGICO', 'Coordenador Pedagógico', 'Currículos, turmas, aulas, exames, progresso, instrutores e processo da carta.', false, 5),
  ('INSTRUTOR', 'Instrutor', 'Instrutor prático: as suas aulas, avaliações e estudantes atribuídos.', false, 6),
  ('PROFESSOR', 'Professor', 'Professor de teórica: as suas turmas, aulas e presenças.', false, 7),
  ('ESTUDANTE', 'Estudante', 'Portal do estudante (dormente até existir portal): os seus próprios dados.', false, 8)
ON CONFLICT (chave) DO UPDATE SET nome = EXCLUDED.nome, descricao = EXCLUDED.descricao, protegido = EXCLUDED.protegido, ordem = EXCLUDED.ordem;

-- Administrador: escopo ESCOLA
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'ADMINISTRADOR', p.id, 'ESCOLA' FROM permissao p
ON CONFLICT DO NOTHING;

-- Gestor de Filial: escopo FILIAL
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'GESTOR_FILIAL', p.id, 'FILIAL' FROM permissao p
WHERE p.codigo IN ('utilizador:ver', 'utilizador:criar', 'utilizador:editar', 'utilizador:desativar', 'utilizador:redefinir_senha', 'perfil:ver', 'permissao:ver', 'auditoria:ver', 'escola:ver', 'filial:ver', 'filial:editar', 'estudante:ver', 'estudante:criar', 'estudante:editar', 'estudante:eliminar', 'estudante:exportar', 'estudante_acesso:gerir', 'anexo:ver', 'anexo:carregar', 'anexo:validar', 'anexo:eliminar', 'anexo_sensivel:ver', 'tipo_documento:ver', 'tipo_documento:gerir', 'documento:gerar', 'documento:ver', 'documento:anular', 'categoria:ver', 'categoria:gerir', 'curriculo:ver', 'curriculo:gerir', 'pacote:ver', 'pacote:gerir', 'turma:ver', 'turma:criar', 'turma:editar', 'turma:cancelar', 'turma:exportar', 'turma_estudante:gerir', 'matricula:ver', 'matricula:criar', 'matricula:editar', 'matricula:cancelar', 'matricula:suspender', 'matricula:reativar', 'aula_teorica:ver', 'aula_teorica:criar', 'aula_teorica:editar', 'aula_teorica:cancelar', 'presenca:ver', 'presenca:registar', 'aula_pratica:ver', 'aula_pratica:agendar', 'aula_pratica:remarcar', 'aula_pratica:cancelar', 'aula_pratica:registar', 'avaliacao:ver', 'avaliacao:registar', 'instrutor:ver', 'instrutor:criar', 'instrutor:editar', 'instrutor:desativar', 'funcionario:ver', 'funcionario:criar', 'funcionario:editar', 'funcionario:desativar', 'exame:ver', 'exame:gerir', 'exame_inscricao:criar', 'exame_inscricao:resultado', 'processo_carta:ver', 'processo_carta:gerir', 'veiculo:ver', 'veiculo:criar', 'veiculo:editar', 'veiculo:desativar', 'manutencao:ver', 'manutencao:registar', 'abastecimento:registar', 'cobranca:ver', 'cobranca:criar', 'cobranca:anular', 'pagamento:ver', 'pagamento:registar', 'pagamento:anular', 'desconto:aplicar', 'despesa:ver', 'despesa:registar', 'despesa:eliminar', 'financeiro_relatorio:ver', 'relatorio:ver', 'relatorio:exportar', 'dashboard:ver', 'notificacao:ver', 'notificacao:enviar')
ON CONFLICT DO NOTHING;

-- Secretaria: escopo FILIAL
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'SECRETARIA', p.id, 'FILIAL' FROM permissao p
WHERE p.codigo IN ('escola:ver', 'filial:ver', 'estudante:ver', 'estudante:criar', 'estudante:editar', 'anexo:ver', 'anexo:carregar', 'tipo_documento:ver', 'categoria:ver', 'curriculo:ver', 'pacote:ver', 'matricula:ver', 'matricula:criar', 'matricula:editar', 'turma:ver', 'turma_estudante:gerir', 'aula_teorica:ver', 'presenca:ver', 'aula_pratica:ver', 'aula_pratica:agendar', 'aula_pratica:remarcar', 'aula_pratica:cancelar', 'avaliacao:ver', 'instrutor:ver', 'veiculo:ver', 'exame:ver', 'exame_inscricao:criar', 'processo_carta:ver', 'cobranca:ver', 'cobranca:criar', 'pagamento:ver', 'pagamento:registar', 'documento:gerar', 'documento:ver', 'notificacao:ver', 'notificacao:enviar', 'dashboard:ver')
ON CONFLICT DO NOTHING;

-- Financeiro: escopo ESCOLA
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'FINANCEIRO', p.id, 'ESCOLA' FROM permissao p
WHERE p.codigo IN ('escola:ver', 'filial:ver', 'estudante:ver', 'estudante:exportar', 'matricula:ver', 'pacote:ver', 'cobranca:ver', 'cobranca:criar', 'cobranca:anular', 'pagamento:ver', 'pagamento:registar', 'pagamento:anular', 'desconto:aplicar', 'despesa:ver', 'despesa:registar', 'despesa:eliminar', 'veiculo:ver', 'manutencao:ver', 'financeiro_relatorio:ver', 'relatorio:ver', 'relatorio:exportar', 'documento:gerar', 'documento:ver', 'notificacao:ver', 'dashboard:ver')
ON CONFLICT DO NOTHING;

-- Coordenador Pedagógico: escopo FILIAL
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'COORDENADOR_PEDAGOGICO', p.id, 'FILIAL' FROM permissao p
WHERE p.codigo IN ('escola:ver', 'filial:ver', 'estudante:ver', 'estudante:exportar', 'anexo:ver', 'anexo:validar', 'tipo_documento:ver', 'categoria:ver', 'categoria:gerir', 'curriculo:ver', 'curriculo:gerir', 'pacote:ver', 'matricula:ver', 'matricula:editar', 'turma:ver', 'turma:criar', 'turma:editar', 'turma:cancelar', 'turma:exportar', 'turma_estudante:gerir', 'aula_teorica:ver', 'aula_teorica:criar', 'aula_teorica:editar', 'aula_teorica:cancelar', 'presenca:ver', 'presenca:registar', 'aula_pratica:ver', 'aula_pratica:agendar', 'aula_pratica:remarcar', 'aula_pratica:cancelar', 'aula_pratica:registar', 'avaliacao:ver', 'avaliacao:registar', 'instrutor:ver', 'instrutor:criar', 'instrutor:editar', 'instrutor:desativar', 'veiculo:ver', 'manutencao:ver', 'exame:ver', 'exame:gerir', 'exame_inscricao:criar', 'exame_inscricao:resultado', 'processo_carta:ver', 'processo_carta:gerir', 'relatorio:ver', 'relatorio:exportar', 'documento:gerar', 'documento:ver', 'notificacao:ver', 'notificacao:enviar', 'dashboard:ver')
ON CONFLICT DO NOTHING;

-- Instrutor: escopo PROPRIO
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'INSTRUTOR', p.id, 'PROPRIO' FROM permissao p
WHERE p.codigo IN ('estudante:ver', 'matricula:ver', 'turma:ver', 'aula_teorica:ver', 'aula_pratica:ver', 'aula_pratica:registar', 'aula_pratica:cancelar', 'avaliacao:ver', 'avaliacao:registar', 'veiculo:ver', 'notificacao:ver', 'dashboard:ver')
ON CONFLICT DO NOTHING;

-- Professor: escopo PROPRIO
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'PROFESSOR', p.id, 'PROPRIO' FROM permissao p
WHERE p.codigo IN ('estudante:ver', 'matricula:ver', 'turma:ver', 'aula_teorica:ver', 'aula_teorica:editar', 'presenca:ver', 'presenca:registar', 'avaliacao:ver', 'notificacao:ver', 'dashboard:ver')
ON CONFLICT DO NOTHING;

-- Estudante: escopo PROPRIO
INSERT INTO perfil_modelo_permissao (perfil_modelo_chave, permissao_id, escopo)
SELECT 'ESTUDANTE', p.id, 'PROPRIO' FROM permissao p
WHERE p.codigo IN ('estudante:ver', 'matricula:ver', 'anexo:ver', 'anexo:carregar', 'documento:ver', 'turma:ver', 'aula_teorica:ver', 'presenca:ver', 'aula_pratica:ver', 'aula_pratica:agendar', 'aula_pratica:cancelar', 'avaliacao:ver', 'exame:ver', 'processo_carta:ver', 'cobranca:ver', 'pagamento:ver', 'notificacao:ver')
ON CONFLICT DO NOTHING;

-- Plano inicial para testes/onboarding. Os planos comerciais são criados pela equipa da plataforma.
INSERT INTO plano (codigo, nome, descricao, preco_mensal) VALUES
  ('TESTE', 'Período de teste', 'Plano gratuito para avaliação, sem limites definidos.', 0)
ON CONFLICT (codigo) DO NOTHING;
