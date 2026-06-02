You are working on Linear issue `{{ issue.identifier }}`.

Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
