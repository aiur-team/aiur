You are working on GitHub issue `{{ issue.identifier }}`.

Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
