# python serve-local.py  ->  http://localhost:8000/local.html#/advertise
import http.server, socketserver
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 8000), http.server.SimpleHTTPRequestHandler) as s:
    print("http://localhost:8000/local.html#/advertise"); s.serve_forever()
