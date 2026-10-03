-- Verify the owner-review token constraints with synthetic data only.
-- Run after 003_owner_review_token.sql. Every data change is rolled back.

BEGIN;

-- Exercise the same table permissions that the n8n Postgres credential uses.
SET LOCAL ROLE mixing_mastering_app;

-- Create one synthetic inquiry that is waiting for an owner decision.
INSERT INTO public.inquiries (
    id,
    submission_key,
    first_name,
    last_name,
    email,
    selected_service,
    message,
    download_url,
    status,
    service_unklar,
    review_reason,
    ai_suggested_service,
    ai_summary,
    email_verified_at
) VALUES (
    '40000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000101',
    'Demo',
    'Review',
    'owner-review@example.invalid',
    'mixing',
    'Synthetic owner review test',
    'https://example.invalid/owner-review',
    'awaiting_owner_review',
    true,
    'service_conflict',
    'mastering',
    'Synthetic summary',
    now()
);

-- A second inquiry exists only to prove that a token cannot cross inquiry boundaries.
INSERT INTO public.inquiries (
    id,
    submission_key,
    first_name,
    last_name,
    email,
    selected_service,
    message,
    download_url,
    status,
    service_unklar,
    review_reason,
    ai_suggested_service,
    ai_summary,
    email_verified_at
) VALUES (
    '40000000-0000-4000-8000-000000000002',
    '40000000-0000-4000-8000-000000000102',
    'Demo',
    'Other',
    'other-review@example.invalid',
    'mastering',
    'Synthetic boundary test',
    'https://example.invalid/other-review',
    'awaiting_owner_review',
    true,
    'service_conflict',
    'mixing',
    'Synthetic second summary',
    now()
);

INSERT INTO public.reply_reviews (
    id,
    inquiry_id,
    draft_text
) VALUES
(
    '40000000-0000-4000-8000-000000000003',
    '40000000-0000-4000-8000-000000000001',
    'Synthetic clarification draft'
),
(
    '40000000-0000-4000-8000-000000000004',
    '40000000-0000-4000-8000-000000000002',
    'Synthetic boundary-test draft'
);

-- This is the valid shape used later by n8n: correct purpose, inquiry and review.
INSERT INTO public.access_tokens (
    inquiry_id,
    purpose,
    token_hash,
    reply_review_id,
    expires_at
) VALUES (
    '40000000-0000-4000-8000-000000000001',
    'owner_review',
    repeat('d', 64),
    '40000000-0000-4000-8000-000000000003',
    now() + interval '24 hours'
);

-- An owner token without a review binding must fail.
DO $$
BEGIN
    BEGIN
        INSERT INTO public.access_tokens (
            inquiry_id, purpose, token_hash, expires_at
        ) VALUES (
            '40000000-0000-4000-8000-000000000001',
            'owner_review', repeat('a', 64), now() + interval '24 hours'
        );
        RAISE EXCEPTION 'Owner token without review binding was accepted';
    EXCEPTION
        WHEN check_violation THEN
            RAISE NOTICE 'Expected: owner token without review binding rejected';
    END;
END
$$;

-- Other token purposes must not gain access to an owner review.
DO $$
BEGIN
    BEGIN
        INSERT INTO public.access_tokens (
            inquiry_id, purpose, token_hash, reply_review_id, expires_at
        ) VALUES (
            '40000000-0000-4000-8000-000000000001',
            'customer_followup', repeat('b', 64),
            '40000000-0000-4000-8000-000000000003',
            now() + interval '24 hours'
        );
        RAISE EXCEPTION 'Customer token with owner review binding was accepted';
    EXCEPTION
        WHEN check_violation THEN
            RAISE NOTICE 'Expected: non-owner token with review binding rejected';
    END;
END
$$;

-- The composite foreign key prevents using a review from another inquiry.
-- A separate review without an existing token isolates this rule from the
-- one-open-token unique index tested below.
DO $$
BEGIN
    BEGIN
        INSERT INTO public.access_tokens (
            inquiry_id, purpose, token_hash, reply_review_id, expires_at
        ) VALUES (
            '40000000-0000-4000-8000-000000000001',
            'owner_review', repeat('c', 64),
            '40000000-0000-4000-8000-000000000004',
            now() + interval '24 hours'
        );
        RAISE EXCEPTION 'Owner token crossed inquiry boundary';
    EXCEPTION
        WHEN foreign_key_violation THEN
            RAISE NOTICE 'Expected: cross-inquiry review binding rejected';
    END;
END
$$;

-- A second open token for the same review must fail to avoid duplicate links.
DO $$
BEGIN
    BEGIN
        INSERT INTO public.access_tokens (
            inquiry_id, purpose, token_hash, reply_review_id, expires_at
        ) VALUES (
            '40000000-0000-4000-8000-000000000001',
            'owner_review', repeat('e', 64),
            '40000000-0000-4000-8000-000000000003',
            now() + interval '24 hours'
        );
        RAISE EXCEPTION 'Second open owner token was accepted';
    EXCEPTION
        WHEN unique_violation THEN
            RAISE NOTICE 'Expected: second open owner token rejected';
    END;
END
$$;

-- Revocation closes the first token and deliberately permits one replacement.
UPDATE public.access_tokens
SET revoked_at = now()
WHERE token_hash = repeat('d', 64);

INSERT INTO public.access_tokens (
    inquiry_id,
    purpose,
    token_hash,
    reply_review_id,
    expires_at
) VALUES (
    '40000000-0000-4000-8000-000000000001',
    'owner_review',
    repeat('e', 64),
    '40000000-0000-4000-8000-000000000003',
    now() + interval '24 hours'
);

-- Expected result: two bound tokens in total, exactly one still open.
SELECT
    count(*) AS owner_token_count,
    count(*) FILTER (
        WHERE used_at IS NULL AND revoked_at IS NULL
    ) AS open_owner_token_count,
    bool_and(reply_review_id = '40000000-0000-4000-8000-000000000003')
        AS all_tokens_bound_to_expected_review
FROM public.access_tokens
WHERE inquiry_id = '40000000-0000-4000-8000-000000000001'
  AND purpose = 'owner_review';

ROLLBACK;

-- No synthetic inquiries may remain after the test.
SELECT count(*) AS synthetic_rows_after_rollback
FROM public.inquiries
WHERE id IN (
    '40000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000002'
);
