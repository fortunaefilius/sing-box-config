import os
import json
import urllib.parse
import requests

GIST_TOKEN = os.environ.get('GIST_TOKEN')
MASTER_GIST_ID = os.environ.get('MASTER_GIST_ID')
CONNECTIONS_GIST_ID = os.environ.get('CONNECTIONS_GIST_ID')
ANDROID_GIST_ID = os.environ.get('ANDROID_GIST_ID')
WINDOWS_GIST_ID = os.environ.get('WINDOWS_GIST_ID')

HEADERS = {
    "Accept": "application/vnd.github+json",
    "Authorization": f"Bearer {GIST_TOKEN}",
    "X-GitHub-Api-Version": "2022-11-28"
}

def get_clean_raw_url(raw_url):
    """Преобразует raw_url с commit_hash в перманентную ссылку без соли."""
    if not raw_url:
        return ""
    # Разбиваем ссылку по фрагменту '/raw/'
    parts = raw_url.split('/raw/')
    if len(parts) == 2:
        # parts[1] имеет вид: 'commit_hash/filename.json'
        subparts = parts[1].split('/')
        if len(subparts) > 1:
            # Отбрасываем хеш коммита и оставляем только имя файла
            filename = '/'.join(subparts[1:])
            return f"{parts[0]}/raw/{filename}"
    return raw_url

def fetch_gist_content(gist_id):
    if not gist_id:
        return None
    try:
        url = f"https://api.github.com/gists/{gist_id}"
        resp = requests.get(url, headers=HEADERS)
        resp.raise_for_status()
        files = resp.json().get('files', {})
        first_key = list(files.keys())[0]
        return files[first_key]['content']
    except Exception as e:
        print(f"Ошибка получения Gist {gist_id}: {e}")
        return None

def build_config(template_str, uuid, server_ip, sni, pbk, sid, apps_list, platform):
    """Генерирует JSON конфигурацию под нужную платформу."""
    field_name = "package_name" if platform == "android" else "process_name"
    
    raw_str = template_str.replace('${VLESS_UUID}', str(uuid)) \
                           .replace('${SERVER_IP}', str(server_ip)) \
                           .replace('${SERVER_SNI}', str(sni)) \
                           .replace('${PUBLIC_KEY}', str(pbk)) \
                           .replace('${SHORT_ID}', str(sid)) \
                           .replace('${APPS_FIELD_NAME}', field_name) \
                           .replace('"${APPS_LIST}"', json.dumps(apps_list))

    config = json.loads(raw_str)

    if platform == "windows":
        for inbound in config.get('inbounds', []):
            if 'include_package' in inbound:
                del inbound['include_package']

    return json.dumps(config, indent=2, ensure_ascii=False)

def main():
    # 1. Читаем шаблон
    with open('config.template.json', 'r', encoding='utf-8') as f:
        template_str = f.read()

    # 2. Скачиваем VLESS ссылки
    vless_raw = fetch_gist_content(CONNECTIONS_GIST_ID)
    if not vless_raw:
        print("Не удалось загрузить vless ссылки.")
        return
    vless_links = json.loads(vless_raw)

    # 3. Скачиваем списки пакетов/процессов
    android_raw = fetch_gist_content(ANDROID_GIST_ID) or "[]"
    windows_raw = fetch_gist_content(WINDOWS_GIST_ID) or "[]"

    try:
        android_apps = json.loads(android_raw)
        windows_apps = json.loads(windows_raw)
    except Exception as e:
        print(f"Ошибка парсинга списков приложений: {e}")
        return

    # 4. Обработка Мастер-гиста (configs.json)
    configs_map = {}
    master_gist_url = None
    needs_new_master = False

    if MASTER_GIST_ID:
        master_gist_url = f"https://api.github.com/gists/{MASTER_GIST_ID}"
        response = requests.get(master_gist_url, headers=HEADERS)
        
        if response.status_code == 200:
            master_files = response.json().get('files', {})
            if 'configs.json' in master_files:
                content = master_files['configs.json'].get('content', '{}')
                try:
                    parsed_content = json.loads(content)
                    if isinstance(parsed_content, dict):
                        configs_map = parsed_content
                except json.JSONDecodeError:
                    pass
        elif response.status_code == 404:
            needs_new_master = True
        else:
            response.raise_for_status()
    else:
        needs_new_master = True

    if needs_new_master:
        print("Создание нового Мастер-гиста...")
        payload = {
            "description": "VLESS Master Configs Map",
            "public": False,
            "files": {"configs.json": {"content": "{}"}}
        }
        create_resp = requests.post("https://api.github.com/gists", headers=HEADERS, json=payload)
        create_resp.raise_for_status()
        new_gist = create_resp.json()
        master_gist_url = new_gist['url']
        print(f"::warning title=MASTER_GIST_ID::Создан новый Мастер-гист ID: {new_gist['id']}")

    # 5. Discovery фаза
    print("Сканирование существующих Gist-файлов...")
    page = 1
    discovered_configs = {}
    
    while True:
        resp = requests.get(f"https://api.github.com/gists?per_page=100&page={page}", headers=HEADERS)
        if resp.status_code != 200 or not resp.json():
            break
            
        for gist in resp.json():
            desc = gist.get('description', '')
            if desc and desc.startswith("Sing-box VLESS Config: "):
                name = desc.replace("Sing-box VLESS Config: ", "").strip()
                
                android_raw_url = gist['files'].get(f"{name}_android.json", {}).get('raw_url', '')
                windows_raw_url = gist['files'].get(f"{name}_windows.json", {}).get('raw_url', '')
                
                discovered_configs[name] = {
                    "name": name,
                    "gist_url": gist['html_url'],
                    "gist_id": gist['id'],
                    "files": {
                        f"{name}_android.json": get_clean_raw_url(android_raw_url),
                        f"{name}_windows.json": get_clean_raw_url(windows_raw_url)
                    }
                }
        page += 1

    for name, data in discovered_configs.items():
        if name not in configs_map:
            configs_map[name] = data

    # 6. Генерация конфигов для каждого сервера VLESS
    for link in vless_links:
        if not isinstance(link, str) or not link.startswith("vless://"):
            continue
            
        parsed = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(parsed.query)
        
        uuid = parsed.username
        server_ip = parsed.hostname
        name = urllib.parse.unquote(parsed.fragment) or f"Unnamed_VLESS_{server_ip}"
        
        sni = params.get('sni', [''])[0]
        pbk = params.get('pbk', [''])[0]
        sid = params.get('sid', [''])[0]

        android_config_json = build_config(template_str, uuid, server_ip, sni, pbk, sid, android_apps, "android")
        windows_config_json = build_config(template_str, uuid, server_ip, sni, pbk, sid, windows_apps, "windows")

        gist_payload = {
            "description": f"Sing-box VLESS Config: {name}",
            "public": False,
            "files": {
                f"{name}_android.json": {"content": android_config_json},
                f"{name}_windows.json": {"content": windows_config_json}
            }
        }

        # 7. Обновление или создание Gist
        if name in configs_map and 'gist_id' in configs_map[name]:
            gist_id = configs_map[name]['gist_id']
            print(f"Обновление Gist для '{name}'...")
            update_resp = requests.patch(f"https://api.github.com/gists/{gist_id}", headers=HEADERS, json=gist_payload)
            
            if update_resp.status_code == 404:
                create_resp = requests.post("https://api.github.com/gists", headers=HEADERS, json=gist_payload)
                create_resp.raise_for_status()
                new_gist = create_resp.json()
                
                configs_map[name] = {
                    "name": name,
                    "gist_url": new_gist['html_url'],
                    "gist_id": new_gist['id'],
                    "files": {
                        f"{name}_android.json": get_clean_raw_url(new_gist['files'][f"{name}_android.json"]['raw_url']),
                        f"{name}_windows.json": get_clean_raw_url(new_gist['files'][f"{name}_windows.json"]['raw_url'])
                    }
                }
            else:
                update_resp.raise_for_status()
                updated_files = update_resp.json().get('files', {})
                
                android_raw = updated_files.get(f"{name}_android.json", {}).get('raw_url', '')
                windows_raw = updated_files.get(f"{name}_windows.json", {}).get('raw_url', '')
                
                configs_map[name]["files"] = {
                    f"{name}_android.json": get_clean_raw_url(android_raw),
                    f"{name}_windows.json": get_clean_raw_url(windows_raw)
                }
        else:
            print(f"Создание нового Gist для '{name}'...")
            create_resp = requests.post("https://api.github.com/gists", headers=HEADERS, json=gist_payload)
            create_resp.raise_for_status()
            new_gist = create_resp.json()
            
            configs_map[name] = {
                "name": name,
                "gist_url": new_gist['html_url'],
                "gist_id": new_gist['id'],
                "files": {
                    f"{name}_android.json": get_clean_raw_url(new_gist['files'][f"{name}_android.json"]['raw_url']),
                    f"{name}_windows.json": get_clean_raw_url(new_gist['files'][f"{name}_windows.json"]['raw_url'])
                }
            }

    # 8. Сохранение реестра конфигураций
    print("Сохранение реестра конфигураций в configs.json...")
    master_payload = {
        "files": {
            "configs.json": {
                "content": json.dumps(configs_map, indent=4, ensure_ascii=False)
            }
        }
    }
    requests.patch(master_gist_url, headers=HEADERS, json=master_payload).raise_for_status()
    print("Успешно завершено!")

if __name__ == "__main__":
    main()
