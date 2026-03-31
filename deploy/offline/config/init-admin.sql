-- Create an admin user with a personal access token for publishing with the CLI.
-- Token: super_token (change this in production!)
INSERT INTO user_data (id, login_name) VALUES (1001, 'admin')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO personal_access_token (id, user_data, value, active, created_timestamp, accessed_timestamp, notified, description)
  VALUES (1001, 1001, 'super_token', true, current_timestamp, current_timestamp, false, 'Admin token for publishing extensions')
  ON CONFLICT (id) DO NOTHING;
