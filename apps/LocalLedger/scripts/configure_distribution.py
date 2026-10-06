import os, sys, time, json
import jwt, requests

API1="https://api.appstoreconnect.apple.com/v1"
API2="https://api.appstoreconnect.apple.com/v2"
BUNDLE_ID="com.yosiken0421.localkakeibo"
BASE_TERRITORY="JPN"

def make_token():
    with open(os.environ["ASC_KEY_PATH"],"r",encoding="utf-8") as f:
        key=f.read()
    now=int(time.time())
    return jwt.encode(
        {"iss":os.environ["ASC_ISSUER_ID_CLEAN"],"iat":now,"exp":now+900,"aud":"appstoreconnect-v1"},
        key,algorithm="ES256",
        headers={"kid":os.environ["ASC_KEY_ID_CLEAN"],"typ":"JWT"},
    )

HEADERS={"Authorization":f"Bearer {make_token()}","Content-Type":"application/json"}

def req(method,url,params=None,payload=None,ok=(200,201,204,404)):
    r=requests.request(method,url,headers=HEADERS,params=params,json=payload,timeout=60)
    print(f"{method} {url.replace('https://api.appstoreconnect.apple.com','')} -> {r.status_code}")
    if r.status_code not in ok:
        print(r.text[:5000])
        raise RuntimeError(f"Unexpected HTTP {r.status_code}")
    if r.status_code==404:
        return None
    if r.status_code==204 or not r.text.strip():
        return {}
    return r.json()

apps=req("GET",API1+"/apps",params={"filter[bundleId]":BUNDLE_ID,"limit":"10"},ok=(200,))
if not apps.get("data"):
    raise RuntimeError("KakeiboLeaf app not found")
app_id=apps["data"][0]["id"]
print("App ID:",app_id)

# ----- Price: free, Japan as base territory -----
price=req("GET",f"{API1}/apps/{app_id}/appPriceSchedule",ok=(200,))
schedule_id=price["data"]["id"]
manual=req("GET",f"{API1}/appPriceSchedules/{schedule_id}/manualPrices",params={"limit":"50"},ok=(200,404))

if manual and manual.get("data"):
    print("Manual app price already configured:",[x["id"] for x in manual["data"]])
else:
    points=req(
        "GET",f"{API1}/apps/{app_id}/appPricePoints",
        params={"filter[territory]":BASE_TERRITORY,"include":"territory","limit":"200"},
        ok=(200,)
    )
    free=None
    for row in points.get("data",[]):
        raw=row.get("attributes",{}).get("customerPrice")
        try:
            value=float(raw)
        except (TypeError,ValueError):
            continue
        if value==0.0:
            free=row
            break
    if not free:
        available=[(x.get("id"),x.get("attributes",{}).get("customerPrice")) for x in points.get("data",[])[:20]]
        print("Sample price points:",available)
        raise RuntimeError("Free JPN price point not found")

    price_point_id=free["id"]
    print("Free JPN price point:",price_point_id)
    temp="${manual-price}"
    payload={
        "data":{
            "type":"appPriceSchedules",
            "relationships":{
                "app":{"data":{"type":"apps","id":app_id}},
                "baseTerritory":{"data":{"type":"territories","id":BASE_TERRITORY}},
                "manualPrices":{"data":[{"type":"appPrices","id":temp}]}
            }
        },
        "included":[{
            "type":"appPrices",
            "id":temp,
            "attributes":{"startDate":None},
            "relationships":{
                "appPricePoint":{"data":{"type":"appPricePoints","id":price_point_id}}
            }
        }]
    }
    created=req("POST",API1+"/appPriceSchedules",payload=payload,ok=(201,))
    schedule_id=created["data"]["id"]
    print("Configured free price schedule:",schedule_id)

base=req("GET",f"{API1}/appPriceSchedules/{schedule_id}/baseTerritory",ok=(200,))
if base["data"]["id"] != BASE_TERRITORY:
    raise RuntimeError("Base territory verification failed")
manual=req("GET",f"{API1}/appPriceSchedules/{schedule_id}/manualPrices",params={"limit":"50"},ok=(200,))
if not manual.get("data"):
    raise RuntimeError("Manual price verification failed")
print("Price schedule verified: FREE / JPN")

# ----- Availability: Japan only initially -----
#
# App Store Connect v2 creates territoryAvailabilities inline. On the first
# creation, send the complete territory set and mark only Japan available.
# Each inline resource uses a local id such as ${JPN}; the real territory
# code belongs in relationships.territory.
availability=req("GET",f"{API1}/apps/{app_id}/appAvailabilityV2")
if availability and availability.get("data"):
    print("Availability already exists:",availability["data"]["id"])
else:
    territory_response=req("GET",API1+"/territories",params={"limit":"200"},ok=(200,))
    territory_ids=sorted(
        row["id"] for row in territory_response.get("data",[])
        if row.get("id")
    )
    if BASE_TERRITORY not in territory_ids:
        raise RuntimeError("Japan territory was not returned by App Store Connect")
    if not territory_ids:
        raise RuntimeError("No App Store territories returned")

    relationship_data=[]
    included=[]
    for territory_id in territory_ids:
        local_id=f"${{{territory_id}}}"
        relationship_data.append({
            "type":"territoryAvailabilities",
            "id":local_id,
        })
        included.append({
            "type":"territoryAvailabilities",
            "id":local_id,
            "attributes":{"available":territory_id == BASE_TERRITORY},
            "relationships":{
                "territory":{"data":{"type":"territories","id":territory_id}}
            },
        })

    print("Creating availability entries:",len(included))
    print("Enabled territories:",[BASE_TERRITORY])
    payload={
        "data":{
            "type":"appAvailabilities",
            "attributes":{"availableInNewTerritories":False},
            "relationships":{
                "app":{"data":{"type":"apps","id":app_id}},
                "territoryAvailabilities":{"data":relationship_data}
            }
        },
        "included":included
    }
    created=req("POST",API2+"/appAvailabilities",payload=payload,ok=(201,))
    print("Created Japan-only availability:",created["data"]["id"])

availability=req("GET",f"{API1}/apps/{app_id}/appAvailabilityV2",ok=(200,))
availability_id=availability["data"]["id"]
territories=req(
    "GET",f"{API2}/appAvailabilities/{availability_id}/territoryAvailabilities",
    params={"include":"territory","limit":"200"},ok=(200,)
)
available_ids=[]
all_ids=[]
for row in territories.get("data",[]):
    rel=row.get("relationships",{}).get("territory",{}).get("data") or {}
    territory_id=rel.get("id")
    if territory_id:
        all_ids.append(territory_id)
        if row.get("attributes",{}).get("available") is True:
            available_ids.append(territory_id)

print("Territory entries:",len(all_ids))
print("Available territories:",sorted(available_ids))
if sorted(set(available_ids)) != [BASE_TERRITORY]:
    raise RuntimeError(f"Japan-only availability verification failed: {sorted(set(available_ids))}")
if BASE_TERRITORY not in all_ids:
    raise RuntimeError("Japan territory entry missing after availability creation")

print("KakeiboLeaf distribution configuration complete: FREE / Japan only.")
