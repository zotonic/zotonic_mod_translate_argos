{% extends "admin_base.tpl" %}

{% block title %}{_ Argos Translate languages _}{% endblock %}

{% block content %}

<div class="admin-header">
    <h2>{_ Argos Translate languages _}</h2>
    <p>{_ Install language packages to enable automatic translations for those language pairs. _}</p>
</div>

{% if m.acl.is_allowed.use.mod_admin_config %}
    <div class="well">
        {% button class="btn btn-default"
                  text=_"Update package list"
                  action={mask target="argos-packages"}
                  action={postback postback={argos_update_packages target="argos-packages"} delegate=`mod_translate_argos`}
        %}
    </div>

    {% wire postback={argos_load_packages target="argos-packages"}
            delegate=`mod_translate_argos`
    %}

    <div id="argos-packages"></div>
{% else %}
    <p class="alert alert-danger">
        {_ You are not allowed to configure Argos Translate. _}
    </p>
{% endif %}

{% endblock %}
