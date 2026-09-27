SELECT status, COUNT(*) AS application_count
FROM applications
WHERE deleted_at IS NULL
GROUP BY status
