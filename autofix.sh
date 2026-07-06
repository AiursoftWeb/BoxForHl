#!/bin/bash
# autofix.sh — fix known quirks in Authentik OIDC configuration
# Run this after deploying Stage 3 (authentik).
set -euo pipefail

get_db_conn() {
    local db_container
    db_container=$(sudo docker ps --filter "name=authentik_postgresql" -q | head -1)
    if [ -z "$db_container" ]; then
        echo "[SKIP] authentik_postgresql not running, skipping Authentik fixes."
        exit 0
    fi
    DB_CONTAINER="$db_container"
    DB_USER=$(sudo docker exec "$db_container" printenv POSTGRES_USER 2>/dev/null || echo "authentik_pg_user")
    DB_NAME=$(sudo docker exec "$db_container" printenv POSTGRES_DB 2>/dev/null || echo "authentik")
}

db_query() {
    sudo docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "$1" 2>/dev/null
}

db_exec() {
    sudo docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "$1" 2>/dev/null
}

fix_ollama_models() {
    echo ""
    echo "--- Ollama Models ---"

    local ollama_cid
    ollama_cid=$(sudo docker ps --filter "name=ollama-server" -q 2>/dev/null | head -1)
    if [ -z "$ollama_cid" ]; then
        echo "[SKIP] Ollama server not running."
        return 0
    fi

    local models=("qwen3.6:35b" "bge-m3:latest")

    for model in "${models[@]}"; do
        if sudo docker exec "$ollama_cid" ollama list 2>/dev/null | grep -q "$model"; then
            echo "[OK]   Ollama model $model already present."
            continue
        fi
        echo "[FIX]  Pulling Ollama model $model..."
        sudo docker exec "$ollama_cid" ollama pull "$model" 2>&1 | tail -1
        echo "[OK]   Ollama model $model pulled."
    done
}

fix_vaultwarden_access_token_validity() {
    local current
    current=$(db_query \
        "SELECT access_token_validity
         FROM authentik_providers_oauth2_oauth2provider p
         JOIN authentik_core_application a ON a.provider_id = p.provider_ptr_id
         WHERE a.slug = 'vaultwarden';" || echo "none")

    if [ "$current" = "none" ] || [ -z "$current" ]; then
        echo "[INFO] Vaultwarden OAuth2 provider not found — configure it in Authentik first."
        return 0
    fi

    echo "[INFO] Vaultwarden provider found. access_token_validity = $current"

    if [ "$current" = "minutes=5" ]; then
        echo "[FIX]  access_token_validity is minutes=5 — Vaultwarden needs >5 min. Fixing to minutes=10..."
        db_exec \
            "UPDATE authentik_providers_oauth2_oauth2provider
             SET access_token_validity = 'minutes=10'
             WHERE provider_ptr_id = (
                 SELECT provider_id FROM authentik_core_application WHERE slug = 'vaultwarden'
             );"
        echo "[OK]   Vaultwarden access_token_validity fixed to minutes=10."
    else
        echo "[OK]   Vaultwarden access_token_validity is already $current."
    fi
}

fix_vaultwarden_email_scope() {
    local provider_id
    provider_id=$(db_query \
        "SELECT p.provider_ptr_id
         FROM authentik_providers_oauth2_oauth2provider p
         JOIN authentik_core_application a ON a.provider_id = p.provider_ptr_id
         WHERE a.slug = 'vaultwarden';" || echo "none")

    if [ "$provider_id" = "none" ] || [ -z "$provider_id" ]; then
        return 0
    fi

    # Check if the custom scope mapping exists
    local custom_scope_uuid
    custom_scope_uuid=$(db_query \
        "SELECT pm.pm_uuid
         FROM authentik_core_propertymapping pm
         JOIN authentik_providers_oauth2_scopemapping sm ON sm.propertymapping_ptr_id = pm.pm_uuid
         WHERE pm.name = 'vaultwarden force email verified';" || echo "")

    # Create custom email scope if missing
    if [ -z "$custom_scope_uuid" ]; then
        echo "[FIX]  Creating custom scope mapping: 'vaultwarden force email verified'..."
        custom_scope_uuid=$(uuidgen)
        db_exec \
            "INSERT INTO authentik_core_propertymapping (pm_uuid, name, expression)
             VALUES ('${custom_scope_uuid}', 'vaultwarden force email verified',
             'return {\"email\": request.user.email, \"email_verified\": True}');"
        db_exec \
            "INSERT INTO authentik_providers_oauth2_scopemapping (propertymapping_ptr_id, scope_name, description)
             VALUES ('${custom_scope_uuid}', 'email',
             'Forces email_verified to True, required by Vaultwarden OIDC SSO.');"
        echo "[OK]   Custom scope mapping created (${custom_scope_uuid})."
    fi

    # Check which email scope is currently linked to the vaultwarden provider
    local linked_email_uuid
    linked_email_uuid=$(db_query \
        "SELECT sm.propertymapping_ptr_id
         FROM authentik_core_provider_property_mappings ppm
         JOIN authentik_providers_oauth2_scopemapping sm ON sm.propertymapping_ptr_id = ppm.propertymapping_id
         WHERE ppm.provider_id = ${provider_id} AND sm.scope_name = 'email';" || echo "")

    if [ "$linked_email_uuid" = "$custom_scope_uuid" ]; then
        echo "[OK]   Vaultwarden uses the custom email scope (email_verified: True)."
    elif [ -n "$linked_email_uuid" ]; then
        echo "[FIX]  Vaultwarden uses default email scope (email_verified: False). Swapping to custom scope..."
        local link_id
        link_id=$(db_query \
            "SELECT ppm.id
             FROM authentik_core_provider_property_mappings ppm
             JOIN authentik_providers_oauth2_scopemapping sm ON sm.propertymapping_ptr_id = ppm.propertymapping_id
             WHERE ppm.provider_id = ${provider_id} AND sm.scope_name = 'email';" || echo "")
        if [ -n "$link_id" ]; then
            db_exec "DELETE FROM authentik_core_provider_property_mappings WHERE id = ${link_id};"
            db_exec \
                "INSERT INTO authentik_core_provider_property_mappings (provider_id, propertymapping_id)
                 VALUES (${provider_id}, '${custom_scope_uuid}');"
            echo "[OK]   Swapped to custom email scope."
        fi
    else
        # No email scope linked yet — add the custom one
        echo "[FIX]  No email scope linked. Adding custom email scope..."
        db_exec \
            "INSERT INTO authentik_core_provider_property_mappings (provider_id, propertymapping_id)
             VALUES (${provider_id}, '${custom_scope_uuid}');"
        echo "[OK]   Custom email scope linked."
    fi
}

fix_app_permissions() {
    echo ""
    echo "--- App OIDC Permissions ---"

    # 9 self-developed Aiursoft apps with MySQL databases
    # Map: stack name -> db service name pattern
    local apps=(
        "employee_db:employeecenter"
        "kanban_db:kanban"
        "marktohtml_db:marktohtml"
        "moongladev2_db:moongladev2"
        "ai_ollama-gateway-db:ollamagateway"
        "stathub_db:stathub"
        "tracer_db:tracer"
        "translate_db:translate"
        "warp_db:warp"
    )

    for entry in "${apps[@]}"; do
        local service_name="${entry%%:*}"
        local app_name="${entry##*:}"
        local db_cid
        db_cid=$(sudo docker ps --filter "name=${service_name}" -q 2>/dev/null | head -1)

        if [ -z "$db_cid" ]; then
            echo "[SKIP] ${app_name}: db container not running."
            continue
        fi

        local db_user db_pass db_name
        db_user=$(sudo docker inspect "$db_cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^MYSQL_USER=' | cut -d= -f2 | head -1)
        db_pass=$(sudo docker inspect "$db_cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^MYSQL_PASSWORD=' | cut -d= -f2 | head -1)
        db_name=$(sudo docker inspect "$db_cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^MYSQL_DATABASE=' | cut -d= -f2 | head -1)

        if [ -z "$db_user" ] || [ -z "$db_pass" ] || [ -z "$db_name" ]; then
            echo "[WARN] ${app_name}: could not extract DB credentials from container env."
            continue
        fi

        # Idempotency check: is Administrators role already deleted?
        local admin_exists
        admin_exists=$(sudo docker exec "$db_cid" mysql -u"$db_user" -p"$db_pass" "$db_name" -sN \
            -e "SELECT count(*) FROM AspNetRoles WHERE Name = 'Administrators';" 2>/dev/null || echo "error")

        if [ "$admin_exists" = "0" ]; then
            # Already fixed — verify employees has claims
            local employee_claims
            employee_claims=$(sudo docker exec "$db_cid" mysql -u"$db_user" -p"$db_pass" "$db_name" -sN \
                -e "SELECT count(*) FROM AspNetRoleClaims rc JOIN AspNetRoles r ON rc.RoleId = r.Id WHERE r.Name = 'employees';" 2>/dev/null || echo "0")
            echo "[OK]   ${app_name}: already fixed (employees=${employee_claims} claims, Administrators gone)."
            continue
        fi

        if [ "$admin_exists" = "error" ]; then
            echo "[SKIP] ${app_name}: AspNetRoles table not found — app may not have started yet."
            continue
        fi

        # Fix: grant all to employees, delete Administrators
        echo -n "[FIX]  ${app_name}: granting all permissions to employees, deleting Administrators... "
        local result
        result=$(sudo docker exec "$db_cid" mysql -u"$db_user" -p"$db_pass" "$db_name" -sN -e "
            SET @roleId = (SELECT Id FROM AspNetRoles WHERE Name = 'employees');
            INSERT IGNORE INTO AspNetRoleClaims (RoleId, ClaimType, ClaimValue)
            SELECT @roleId, c.ClaimType, c.ClaimValue
            FROM (SELECT DISTINCT ClaimType, ClaimValue FROM AspNetRoleClaims) AS c
            WHERE NOT EXISTS (
                SELECT 1 FROM AspNetRoleClaims
                WHERE RoleId = @roleId AND ClaimType = c.ClaimType AND ClaimValue = c.ClaimValue
            );
            SET @adminRoleId = (SELECT Id FROM AspNetRoles WHERE Name = 'Administrators');
            DELETE FROM AspNetRoleClaims WHERE RoleId = @adminRoleId;
            DELETE FROM AspNetRoles WHERE Id = @adminRoleId;
            SELECT CONCAT((SELECT count(*) FROM AspNetRoleClaims rc JOIN AspNetRoles r ON rc.RoleId = r.Id WHERE r.Name = 'employees'), ' claims');
        " 2>/dev/null || echo "FAIL")
        echo "$result"
    done
}

echo "============================================"
echo " autofix.sh — Automatic fixups"
echo "============================================"
get_db_conn
fix_vaultwarden_access_token_validity
fix_vaultwarden_email_scope
fix_app_permissions
fix_ollama_models
echo ""
echo "Done."
