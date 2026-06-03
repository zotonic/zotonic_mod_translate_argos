{% with m.translate_argos.packages as result %}
    {% if result.error %}
        <p class="alert alert-danger">
            {_ Could not load the Argos Translate language packages. _}
            <br>
            <code>{{ result.error|escape }}</code>
        </p>
    {% else %}
        <div class="widget">
            <div class="widget-header">{_ Available language packages _}</div>
            <div class="widget-content">
                <table class="table table-striped do_adminLinkedTable">
                    <thead>
                        <tr>
                            <th>{_ From _}</th>
                            <th>{_ To _}</th>
                            <th>{_ Package _}</th>
                            <th>{_ Version _}</th>
                            <th class="text-right">{_ Status _}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for p in result.packages %}
                            {% with forloop.counter as index %}
                                {% with #package.index as row_id %}
                                    <tr id="{{ row_id }}">
                                        {% include "_admin_translate_argos_package.tpl" p=p row_id=row_id %}
                                    </tr>
                                {% endwith %}
                            {% endwith %}
                        {% empty %}
                            <tr>
                                <td colspan="5">{_ No Argos Translate language packages found. _}</td>
                            </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    {% endif %}
{% endwith %}
