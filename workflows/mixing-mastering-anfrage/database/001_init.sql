-- Demo schema for the Mixing/Mastering inquiry workflow.
-- Run as the database administrator against mixing_mastering_demo only.
-- This file contains no credentials or customer data.

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'mixing_mastering_demo' THEN
        RAISE EXCEPTION 'This migration must run against mixing_mastering_demo';
    END IF;
END
$$;

CREATE TABLE public.inquiries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name text NOT NULL CHECK (btrim(first_name) <> ''),
    last_name text NOT NULL CHECK (btrim(last_name) <> ''),
    email text NOT NULL CHECK (btrim(email) <> ''),
    selected_service text NOT NULL CHECK (selected_service IN ('mixing', 'mastering', 'mixing_and_mastering')),
    confirmed_service text CHECK (confirmed_service IN ('mixing', 'mastering', 'mixing_and_mastering')),
    message text NOT NULL CHECK (btrim(message) <> ''),
    download_url text NOT NULL CHECK (btrim(download_url) <> ''),
    status text NOT NULL DEFAULT 'pending_verification' CHECK (
        status IN (
            'pending_verification', 'verification_expired', 'evaluating',
            'ready_for_processing', 'awaiting_owner_review',
            'awaiting_customer', 'manual_review'
        )
    ),
    service_unklar boolean NOT NULL DEFAULT false,
    review_reason text CHECK (
        review_reason IN (
            'service_conflict', 'service_ambiguous', 'possible_personal_data',
            'ai_invalid', 'followup_limit'
        )
    ),
    ai_suggested_service text CHECK (ai_suggested_service IN ('mixing', 'mastering', 'mixing_and_mastering')),
    ai_summary text,
    followup_count integer NOT NULL DEFAULT 0 CHECK (followup_count BETWEEN 0 AND 2),
    notion_page_id text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    email_verified_at timestamptz,
    CONSTRAINT unclear_service_has_no_confirmation CHECK (NOT service_unklar OR confirmed_service IS NULL),
    CONSTRAINT verified_status_has_timestamp CHECK (
        (status IN ('pending_verification', 'verification_expired') AND email_verified_at IS NULL)
        OR
        (status NOT IN ('pending_verification', 'verification_expired') AND email_verified_at IS NOT NULL)
    )
);

CREATE TABLE public.access_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inquiry_id uuid NOT NULL REFERENCES public.inquiries(id),
    purpose text NOT NULL CHECK (purpose IN ('email_verification', 'customer_followup')),
    token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT access_token_inquiry_pair UNIQUE (id, inquiry_id),
    CONSTRAINT access_token_expiry_after_creation CHECK (expires_at > created_at)
);

CREATE INDEX access_tokens_inquiry_id_idx ON public.access_tokens(inquiry_id);

CREATE TABLE public.inquiry_updates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inquiry_id uuid NOT NULL REFERENCES public.inquiries(id),
    access_token_id uuid NOT NULL UNIQUE,
    service_selection text CHECK (service_selection IN ('mixing', 'mastering', 'mixing_and_mastering')),
    message text CHECK (message IS NULL OR btrim(message) <> ''),
    download_url text CHECK (download_url IS NULL OR btrim(download_url) <> ''),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT inquiry_update_has_content CHECK (
        service_selection IS NOT NULL OR message IS NOT NULL OR download_url IS NOT NULL
    ),
    CONSTRAINT inquiry_update_token_matches_inquiry FOREIGN KEY (access_token_id, inquiry_id)
        REFERENCES public.access_tokens(id, inquiry_id)
);

CREATE INDEX inquiry_updates_inquiry_id_idx ON public.inquiry_updates(inquiry_id);

CREATE TABLE public.reply_reviews (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inquiry_id uuid NOT NULL REFERENCES public.inquiries(id),
    draft_text text NOT NULL CHECK (btrim(draft_text) <> ''),
    edited_text text CHECK (edited_text IS NULL OR btrim(edited_text) <> ''),
    decision text NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'approved', 'rejected')),
    decided_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT reply_review_decision_timestamp CHECK (
        (decision = 'pending' AND decided_at IS NULL)
        OR (decision <> 'pending' AND decided_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX reply_reviews_one_pending_per_inquiry_idx
    ON public.reply_reviews(inquiry_id) WHERE decision = 'pending';

CREATE TABLE public.outbound_actions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inquiry_id uuid NOT NULL REFERENCES public.inquiries(id),
    kind text NOT NULL CHECK (
        kind IN (
            'verification_email', 'acknowledgement_email', 'clarification_email',
            'owner_notification', 'notion_upsert'
        )
    ),
    idempotency_key text NOT NULL UNIQUE CHECK (btrim(idempotency_key) <> ''),
    state text NOT NULL DEFAULT 'pending' CHECK (
        state IN ('pending', 'in_progress', 'succeeded', 'failed', 'needs_review')
    ),
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    last_attempt_at timestamptz,
    completed_at timestamptz,
    external_reference text,
    last_error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT completed_action_timestamp CHECK (state <> 'succeeded' OR completed_at IS NOT NULL)
);

CREATE INDEX outbound_actions_inquiry_id_idx ON public.outbound_actions(inquiry_id);

GRANT SELECT, INSERT, UPDATE ON
    public.inquiries,
    public.access_tokens,
    public.inquiry_updates,
    public.reply_reviews,
    public.outbound_actions
TO mixing_mastering_app;

COMMIT;
