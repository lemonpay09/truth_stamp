alter table public.stamps
  add column if not exists thumbnail_base64 text,
  add column if not exists heatmap_base64 text,
  add column if not exists metadata_score text,
  add column if not exists forgery_score text,
  add column if not exists conclusion text;
