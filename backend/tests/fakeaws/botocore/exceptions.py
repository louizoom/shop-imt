class ClientError(Exception):
    def __init__(self, response, op):
        super().__init__(response["Error"]["Code"]); self.response = response
