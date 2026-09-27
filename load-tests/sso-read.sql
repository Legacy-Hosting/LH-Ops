SELECT role_key, COUNT(*) AS assignment_count
FROM sso_user_roles
GROUP BY role_key
