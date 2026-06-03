<td>{{ p.from_name|default:p.from_code|escape }} <span class="text-muted">{{ p.from_code|escape }}</span></td>
<td>{{ p.to_name|default:p.to_code|escape }} <span class="text-muted">{{ p.to_code|escape }}</span></td>
<td><code>{{ p.name|escape }}</code></td>
<td>
    {{ p.version|escape }}
    {% if p.outdated %}
        <span class="text-muted">{_ Installed _}: {{ p.installed_version|escape }}</span>
    {% endif %}
</td>
<td class="text-right">
    {% if p.installed %}
        <span class="label label-success">{_ Installed _}</span>
        {% if p.outdated %}
            {% button class="btn btn-warning"
                      text=[_"Update", " ", p.from_code, " → ", p.to_code]
                      action={mask target=row_id}
                      action={postback postback={argos_install_package name=p.name target=row_id} delegate=`mod_translate_argos`}
            %}
        {% endif %}
    {% else %}
        {% button class="btn btn-primary"
                  text=[_"Install", " ", p.from_code, " → ", p.to_code]
                  action={mask target=row_id}
                  action={postback postback={argos_install_package name=p.name target=row_id} delegate=`mod_translate_argos`}
        %}
    {% endif %}
</td>
