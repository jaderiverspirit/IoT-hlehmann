
# Executed exclusively INSIDE the local GitLab container
# via gitlab-rails runner.
#
# Generate a dedicated personal access token for the
# local IoT GitLab bootstrap and Git operations.

user = User.find_by_username('root')
raise 'GitLab root user does not exist' unless user
raise 'GitLab root user is not active' unless user.active?

name = 'IoT local lab bootstrap'
token_value = ENV.fetch('IOT_GITLAB_PAT')

raise 'Invalid bootstrap token length' if token_value.length < 20

# Perform token replacement within a database transaction.
# Roll back changes if token creation or revocation fails.
PersonalAccessToken.transaction do

  pat = user.personal_access_tokens.build(
    name: name,
    scopes: ['api'],
    expires_at: 90.days.from_now
  )

  pat.set_token(token_value)
  pat.save!

  # Revoke previous bootstrap tokens only after the
  # replacement token has been successfully created.
  user.personal_access_tokens
      .where(name: name)
      .where.not(id: pat.id)
      .where(revoked: false)
      .each(&:revoke!)

end

puts 'IoT GitLab bootstrap token created successfully'
