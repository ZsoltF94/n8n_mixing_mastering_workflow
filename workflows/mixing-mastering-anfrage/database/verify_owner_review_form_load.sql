-- Verify the read-only SQL used by the owner-review GET form.
-- Synthetic cases cover every public outcome; all fixture rows are rolled back.

BEGIN;

SET LOCAL ROLE mixing_mastering_app;

INSERT INTO public.inquiries (
    id, submission_key, first_name, last_name, email, selected_service,
    message, download_url, status, service_unklar, review_reason,
    ai_suggested_service, ai_summary, email_verified_at
) VALUES
('70000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000101', 'Demo', 'Valid', 'valid@example.invalid', 'mixing_and_mastering', 'Valid synthetic message', 'https://example.invalid/valid', 'awaiting_owner_review', true, 'service_conflict', 'mixing', 'Valid synthetic summary', now()),
('70000000-0000-4000-8000-000000000002', '70000000-0000-4000-8000-000000000102', 'Demo', 'Used', 'used@example.invalid', 'mixing', 'Used synthetic message', 'https://example.invalid/used', 'awaiting_owner_review', true, 'service_conflict', 'mastering', 'Used synthetic summary', now()),
('70000000-0000-4000-8000-000000000003', '70000000-0000-4000-8000-000000000103', 'Demo', 'Revoked', 'revoked@example.invalid', 'mastering', 'Revoked synthetic message', 'https://example.invalid/revoked', 'awaiting_owner_review', true, 'service_conflict', 'mixing', 'Revoked synthetic summary', now()),
('70000000-0000-4000-8000-000000000004', '70000000-0000-4000-8000-000000000104', 'Demo', 'Expired', 'expired@example.invalid', 'mixing', 'Expired synthetic message', 'https://example.invalid/expired', 'awaiting_owner_review', true, 'service_conflict', 'mastering', 'Expired synthetic summary', now()),
('70000000-0000-4000-8000-000000000005', '70000000-0000-4000-8000-000000000105', 'Demo', 'Decided', 'decided@example.invalid', 'mastering', 'Decided synthetic message', 'https://example.invalid/decided', 'awaiting_owner_review', true, 'service_conflict', 'mixing', 'Decided synthetic summary', now()),
('70000000-0000-4000-8000-000000000006', '70000000-0000-4000-8000-000000000106', 'Demo', 'Unavailable', 'unavailable@example.invalid', 'mixing_and_mastering', 'Unavailable synthetic message', 'https://example.invalid/unavailable', 'manual_review', true, 'service_ambiguous', NULL, 'Unavailable synthetic summary', now());

INSERT INTO public.reply_reviews (id, inquiry_id, draft_text, decision, decided_at) VALUES
('70000000-0000-4000-8000-000000000011', '70000000-0000-4000-8000-000000000001', 'Valid synthetic draft', 'pending', NULL),
('70000000-0000-4000-8000-000000000012', '70000000-0000-4000-8000-000000000002', 'Used synthetic draft', 'pending', NULL),
('70000000-0000-4000-8000-000000000013', '70000000-0000-4000-8000-000000000003', 'Revoked synthetic draft', 'pending', NULL),
('70000000-0000-4000-8000-000000000014', '70000000-0000-4000-8000-000000000004', 'Expired synthetic draft', 'pending', NULL),
('70000000-0000-4000-8000-000000000015', '70000000-0000-4000-8000-000000000005', 'Decided synthetic draft', 'approved', now()),
('70000000-0000-4000-8000-000000000016', '70000000-0000-4000-8000-000000000006', 'Unavailable synthetic draft', 'pending', NULL);

INSERT INTO public.access_tokens (
    inquiry_id, reply_review_id, purpose, token_hash,
    expires_at, used_at, revoked_at, created_at
) VALUES
('70000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000011', 'owner_review', repeat('a', 64), now() + interval '24 hours', NULL, NULL, now()),
('70000000-0000-4000-8000-000000000002', '70000000-0000-4000-8000-000000000012', 'owner_review', repeat('b', 64), now() + interval '24 hours', now(), NULL, now()),
('70000000-0000-4000-8000-000000000003', '70000000-0000-4000-8000-000000000013', 'owner_review', repeat('c', 64), now() + interval '24 hours', NULL, now(), now()),
('70000000-0000-4000-8000-000000000004', '70000000-0000-4000-8000-000000000014', 'owner_review', repeat('d', 64), now() - interval '24 hours', NULL, NULL, now() - interval '48 hours'),
('70000000-0000-4000-8000-000000000005', '70000000-0000-4000-8000-000000000015', 'owner_review', repeat('e', 64), now() + interval '24 hours', NULL, NULL, now()),
('70000000-0000-4000-8000-000000000006', '70000000-0000-4000-8000-000000000016', 'owner_review', repeat('f', 64), now() + interval '24 hours', NULL, NULL, now());

-- Mirrors the query in the n8n node. It performs no mutation.
PREPARE load_owner_review_form(text) AS
WITH matched AS MATERIALIZED (
  SELECT
    token.expires_at,
    token.used_at,
    token.revoked_at,
    review.decision,
    review.draft_text,
    inquiry.status,
    inquiry.first_name,
    inquiry.last_name,
    inquiry.email,
    inquiry.selected_service,
    inquiry.review_reason,
    inquiry.message,
    inquiry.download_url,
    inquiry.ai_summary
  FROM public.access_tokens AS token
  JOIN public.reply_reviews AS review
    ON review.id = token.reply_review_id
   AND review.inquiry_id = token.inquiry_id
  JOIN public.inquiries AS inquiry
    ON inquiry.id = token.inquiry_id
  WHERE token.token_hash = $1
    AND token.purpose = 'owner_review'
), classified AS (
  SELECT
    *,
    CASE
      WHEN used_at IS NOT NULL THEN 'already_used'
      WHEN revoked_at IS NOT NULL THEN 'revoked'
      WHEN expires_at <= now() THEN 'expired'
      WHEN decision <> 'pending' THEN 'already_decided'
      WHEN status <> 'awaiting_owner_review' THEN 'unavailable'
      ELSE 'valid'
    END AS outcome
  FROM matched
)
SELECT
  COALESCE(classified.outcome, 'invalid') AS outcome,
  CASE WHEN classified.outcome = 'valid' THEN classified.first_name END AS first_name,
  CASE WHEN classified.outcome = 'valid' THEN classified.last_name END AS last_name,
  CASE WHEN classified.outcome = 'valid' THEN classified.email END AS email,
  CASE WHEN classified.outcome = 'valid' THEN classified.selected_service END AS selected_service,
  CASE WHEN classified.outcome = 'valid' THEN classified.review_reason END AS review_reason,
  CASE WHEN classified.outcome = 'valid' THEN classified.message END AS message,
  CASE WHEN classified.outcome = 'valid' THEN classified.download_url END AS download_url,
  CASE WHEN classified.outcome = 'valid' THEN classified.ai_summary END AS ai_summary,
  CASE WHEN classified.outcome = 'valid' THEN classified.draft_text END AS draft_text,
  CASE WHEN classified.outcome = 'valid' THEN classified.expires_at END AS expires_at
FROM (SELECT 1) AS singleton
LEFT JOIN classified ON true
LIMIT 1;

-- Expected outcomes in order: valid, already_used, revoked, expired,
-- already_decided, unavailable, invalid. Only valid may return context fields.
EXECUTE load_owner_review_form(repeat('a', 64));
EXECUTE load_owner_review_form(repeat('b', 64));
EXECUTE load_owner_review_form(repeat('c', 64));
EXECUTE load_owner_review_form(repeat('d', 64));
EXECUTE load_owner_review_form(repeat('e', 64));
EXECUTE load_owner_review_form(repeat('f', 64));
EXECUTE load_owner_review_form(repeat('0', 64));

ROLLBACK;

SELECT count(*) AS synthetic_rows_after_rollback
FROM public.inquiries
WHERE id BETWEEN
    '70000000-0000-4000-8000-000000000001'::uuid
    AND '70000000-0000-4000-8000-000000000006'::uuid;
