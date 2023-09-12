import requests
import base64

rpc_url = "http://192.168.0.105:39091/transmission/rpc"
username = "xxxx"
password = "xxxx"
headers = {
    "Content-Type": "application/json",
    "Authorization": 'Basic ' + str(base64.b64encode(f'{username}:{password}'.encode('utf-8'))).split("'")[1]
}

# 获取sessionid


def get_sessionid():
    try:
        response = requests.post(rpc_url, headers=headers)
        sessionid = response.headers['X-Transmission-Session-Id']
        headers['X-Transmission-Session-Id'] = sessionid
    except requests.exceptions.RequestException as e:
        print('Error:', str(e))
        return False
    return True


# 对RPC发送请求,获取返回的json
def get_rpc_response_json(payload):
    try:
        response = requests.post(rpc_url, json=payload, headers=headers)
    except requests.exceptions.RequestException:
        print("连接RPC失败")
    return response.json()


# 获取确实的种子列表
def get_lack_tracker_torrents() -> list:
    idlist = []
    torrents = []
    gettorrentpayload = {
        "method": "torrent-get",
        "arguments": {
            "fields": ["id", "name", "trackers"]
        },
        "tag": ""
    }

    gettorrentresponse_json = get_rpc_response_json(gettorrentpayload)
    if gettorrentresponse_json['result'] == 'success':
        for list in gettorrentresponse_json["arguments"]["torrents"]:
            if (len(list["trackers"]) == 1):
                temp = list["trackers"][0]
                if "t.audiences.me" in temp["announce"] or "tracker.cinefiles.info" in temp["announce"]:
                    torrent = {}
                    torrent["name"] = list["name"]
                    torrent["ids"] = list["id"]
                    torrent["announce"] = temp["announce"]
                    torrents.append(torrent)
                    idlist.append(temp["id"])
        print("需要修改的种子数量为：" + str(len(torrents)))
    return torrents


# 对种子列表添加缺失的tracker
def set_lack_tracker_torrents(torrents):
    if len(torrents) != 0:
        idlist = []
        for torrent in torrents:
            trackerAdd = []
            if "t.audiences.me" in torrent["announce"]:
                new_tracker = torrent["announce"].replace(
                    "t.audiences.me", "tracker.cinefiles.info")
                trackerAdd.append(new_tracker)
            elif "tracker.cinefiles.info" in torrent["announce"]:
                new_tracker = torrent["announce"].replace(
                    "tracker.cinefiles.info", "t.audiences.me")
                trackerAdd.append(new_tracker)
            settorrent_payload = {
                "method": "torrent-set",
                "arguments": {
                    "ids": torrent["ids"],
                    "trackerAdd": trackerAdd
                },
                "tag": ""
            }
            settorrent_response_json = get_rpc_response_json(settorrent_payload)
            print(torrent["name"] + "  " + settorrent_response_json["result"])
            idlist.append(torrent["ids"])

        # 对修改好的tracker重新获取Peers
        reannouncepayload = {
            'method': 'torrent-reannounce',
            'arguments': {
                'ids': idlist
            }
        }
        reannounceresponse_json = get_rpc_response_json(reannouncepayload)
        if reannounceresponse_json['result'] == 'success':
            print("全部重新获取Peer")


if __name__ == "__main__":
    if get_sessionid():
        torrents = get_lack_tracker_torrents()
        set_lack_tracker_torrents(torrents)