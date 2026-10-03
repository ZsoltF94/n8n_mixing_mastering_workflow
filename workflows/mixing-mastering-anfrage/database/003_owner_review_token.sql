-- Extend access tokens for the internal owner review form.
-- Run once as the database administrator against mixing_mastering_demo.
-- The raw token never enters PostgreSQL; access_tokens stores only its SHA-256 hash.

BEGIN;

-- Stop immediately if this migration is accidentally run against another database.
DO $$
BEGIN
    IF current_database() <> 'mixing_mastering_demo' THEN
        RAISE EXCEPTION 'This migration must run against mixing_mastering_demo';
    END IF;
END
$$;

-- A token must point to the exact review and inquiry that it authorizes.
-- The additional unique pair lets the composite foreign key enforce both values together.
ALTER TABLE public.reply_reviews
    ADD CONSTRAINT reply_review_inquiry_pair UNIQUE (id, inquiry_id);

ALTER TABLE public.access_tokens
    ADD COLUMN reply_review_id uuid;

ALTER TABLE public.access_tokens
    DROP CONSTRAINT access_tokens_purpose_check,
    ADD CONSTRAINT access_tokens_purpose_check CHECK (
        purpose IN ('email_verification', 'customer_followup', 'owner_review')
    ),
    ADD CONSTRAINT access_token_review_matches_inquiry
        FOREIGN KEY (reply_review_id, inquiry_id)
        REFERENCES public.reply_reviews(id, inquiry_id),
    ADD CONSTRAINT access_token_review_binding CHECK (
        (purpose = 'owner_review' AND reply_review_id IS NOT NULL)
        OR
        (purpose <> 'owner_review' AND reply_review_id IS NULL)
    );

-- Only one unused and non-revoked owner token may exist for one open review.
-- Before a replacement is created, an expired token must therefore be revoked.
CREATE UNIQUE INDEX access_tokens_one_open_owner_review_token_idx
    ON public.access_tokens(reply_review_id)
    WHERE purpose = 'owner_review'
      AND used_at IS NULL
      AND revoked_at IS NULL;

COMMIT;
