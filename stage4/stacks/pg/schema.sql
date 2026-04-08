-- PostgreSQL Schema: 财报解析与向量知识库 (pgvector)
-- FinDataEngine v2 — 768 维 nomic-embed-text

CREATE EXTENSION IF NOT EXISTS vector;

-- 1. 财报层级 MD 原文表 (供 main_factory 消费)
CREATE TABLE IF NOT EXISTS ai_fin_report_md (
    file_id INTEGER PRIMARY KEY,
    reit_code VARCHAR(50),
    report_period VARCHAR(20),
    report_type VARCHAR(20),
    full_text_md TEXT,
    toc_json JSONB,
    sections_json JSONB,
    md_minio_url VARCHAR(500),
    json_minio_url VARCHAR(500),
    status VARCHAR(20),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. 财报向量分段表 (768 维 nomic-embed-text)
CREATE TABLE IF NOT EXISTS chong_fin_report_vector_v1 (
    id BIGINT PRIMARY KEY,
    file_id INTEGER NOT NULL,
    chunk_id VARCHAR(200) UNIQUE NOT NULL,
    reit_code VARCHAR(50),
    rp_period VARCHAR(20),
    report_type VARCHAR(20),
    section_num VARCHAR(20),
    section_title VARCHAR(200),
    section_level INTEGER DEFAULT 0,
    breadcrumb TEXT,
    content TEXT,
    embedding vector(768),
    has_table BOOLEAN DEFAULT FALSE,
    fts_tokens tsvector,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_vector_v1_ivfflat
    ON chong_fin_report_vector_v1 USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX IF NOT EXISTS idx_vector_v1_fts
    ON chong_fin_report_vector_v1 USING gin (fts_tokens);
CREATE INDEX IF NOT EXISTS idx_vector_v1_file_chunk
    ON chong_fin_report_vector_v1 (file_id, chunk_id);
CREATE INDEX IF NOT EXISTS idx_vector_v1_reit
    ON chong_fin_report_vector_v1 (reit_code, rp_period);

-- 3. 财报目录表
CREATE TABLE IF NOT EXISTS chong_fin_report_toc_v1 (
    id BIGSERIAL PRIMARY KEY,
    file_id INTEGER NOT NULL,
    section_num VARCHAR(20) NOT NULL,
    section_title VARCHAR(200),
    level INTEGER DEFAULT 1,
    breadcrumb TEXT,
    parent_section_num VARCHAR(20),
    content_length INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (file_id, section_num)
);

CREATE INDEX IF NOT EXISTS idx_toc_v1_file
    ON chong_fin_report_toc_v1 (file_id);

-- 4. 财报分页布局表
CREATE TABLE IF NOT EXISTS chong_fin_report_layout_v1 (
    id BIGSERIAL PRIMARY KEY,
    file_id INTEGER NOT NULL,
    page_num INTEGER NOT NULL,
    char_start INTEGER,
    char_end INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_layout_v1_file
    ON chong_fin_report_layout_v1 (file_id);

-- 保留旧表兼容（如果已存在则不动）
-- ai_fin_report_vectors 旧 1536 维表保留给历史数据
