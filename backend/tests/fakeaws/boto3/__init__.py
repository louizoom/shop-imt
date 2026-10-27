import copy
from decimal import Decimal
from botocore.exceptions import ClientError
from boto3.dynamodb.types import TypeDeserializer
TABLES = {}   # nom -> {cle: item ddb-json}
KEYS = {}     # nom -> attribut cle
PUBLISHED, S3, EXECUTIONS, EMAILS, NON_VERIFIES, IDENTITES = [], {}, {}, [], set(), []
SCHEDULES = {}   # (groupe, nom) -> paramètres
def _k(t, key): return key[KEYS[t]]["S"]
class _DDB:
    def scan(self, TableName, **kw): return {"Items": [copy.deepcopy(i) for i in TABLES[TableName].values()]}
    def batch_get_item(self, RequestItems):
        out = {}
        for t, spec in RequestItems.items():
            out[t] = [copy.deepcopy(TABLES[t][_k(t, k)]) for k in spec["Keys"] if _k(t, k) in TABLES[t]]
        return {"Responses": out}
    def get_item(self, TableName, Key, ConsistentRead=False):
        it = TABLES[TableName].get(_k(TableName, Key))
        return {"Item": copy.deepcopy(it)} if it else {}
    def transact_write_items(self, TransactItems):
        snap = copy.deepcopy(TABLES)
        try:
            for op in TransactItems:
                if "Update" in op:
                    u = op["Update"]; it = TABLES[u["TableName"]][_k(u["TableName"], u["Key"])]
                    q = Decimal(u["ExpressionAttributeValues"][":q"]["N"])
                    if Decimal(it["stock"]["N"]) < q: raise ClientError({"Error": {"Code": "TransactionCanceledException"}}, "x")
                    it["stock"]["N"] = str(Decimal(it["stock"]["N"]) - q)
                else:
                    p = op["Put"]; TABLES[p["TableName"]][_k(p["TableName"], p["Item"])] = copy.deepcopy(p["Item"])
        except ClientError:
            TABLES.clear(); TABLES.update(snap); raise
    def query(self, TableName, IndexName, KeyConditionExpression, ExpressionAttributeValues, ScanIndexForward=True, Limit=None, ExclusiveStartKey=None):
        attr, cle = ("jour", ":j") if IndexName == "par-jour" else ("client_sub", ":s")
        val = ExpressionAttributeValues[cle]["S"]
        items = [copy.deepcopy(i) for i in TABLES[TableName].values() if i.get(attr, {}).get("S") == val]
        items.sort(key=lambda i: i["cree_le"]["S"], reverse=not ScanIndexForward)
        return {"Items": items[:Limit]}
    def update_item(self, TableName, Key, UpdateExpression, ExpressionAttributeValues, ConditionExpression="", ReturnValues=None):
        if UpdateExpression == "SET stock = stock + :d":   # réassort admin : compteur atomique borné
            it = TABLES[TableName].get(_k(TableName, Key))
            v = ExpressionAttributeValues
            if it is None or not (Decimal(v[":min"]["N"]) <= Decimal(it["stock"]["N"]) <= Decimal(v[":max"]["N"])):
                raise ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "UpdateItem")
            it["stock"]["N"] = str(Decimal(it["stock"]["N"]) + Decimal(v[":d"]["N"]))
            return {"Attributes": copy.deepcopy(it)}
        it = TABLES[TableName][_k(TableName, Key)]
        if "attribute_not_exists(numero_suivi)" in ConditionExpression and "numero_suivi" in it:
            raise ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "UpdateItem")
        for part in UpdateExpression[len("SET "):].split(", "):
            attr, val = part.split(" = ")
            if val.startswith("list_append"):
                it[attr]["L"].extend(ExpressionAttributeValues[val.split(", ")[1].rstrip(")")]["L"])
            else:
                it[attr] = ExpressionAttributeValues[val]
class _SNS:
    def publish(self, **kw): PUBLISHED.append(kw)
class _SFN:
    def start_execution(self, stateMachineArn, name, input):
        if name in EXECUTIONS:
            raise ClientError({"Error": {"Code": "ExecutionAlreadyExists"}}, "StartExecution")
        EXECUTIONS[name] = input
class _SES:
    def send_email(self, FromEmailAddress, Destination, Content):
        if set(Destination["ToAddresses"]) & NON_VERIFIES:
            raise ClientError({"Error": {"Code": "MessageRejected", "Message": "Email address is not verified."}}, "SendEmail")
        EMAILS.append({"from": FromEmailAddress, "to": Destination["ToAddresses"], **Content["Simple"]})
    def create_email_identity(self, EmailIdentity, Tags=()):
        if EmailIdentity in IDENTITES:
            raise ClientError({"Error": {"Code": "AlreadyExistsException", "Message": "exists"}}, "CreateEmailIdentity")
        IDENTITES.append(EmailIdentity)
class _Scheduler:
    def create_schedule(self, Name, GroupName, **kw):
        if (GroupName, Name) in SCHEDULES:
            raise ClientError({"Error": {"Code": "ConflictException"}}, "CreateSchedule")
        SCHEDULES[(GroupName, Name)] = kw
    def delete_schedule(self, Name, GroupName):
        if SCHEDULES.pop((GroupName, Name), None) is None:
            raise ClientError({"Error": {"Code": "ResourceNotFoundException"}}, "DeleteSchedule")
TRADUCTIONS = []
class _Translate:
    def translate_text(self, Text, SourceLanguageCode, TargetLanguageCode):
        TRADUCTIONS.append(Text); return {"TranslatedText": {"T-shirt": "T-shirt", "Mug": "Mug"}.get(Text, f"[en] {Text}")}
class _S3:
    def put_object(self, Bucket, Key, Body, ContentType): S3[Key] = Body
    def generate_presigned_url(self, op, Params, ExpiresIn): return f"https://{Params['Bucket']}.s3.test/{Params['Key']}?expire={ExpiresIn}"
class _Table:
    def __init__(self, n): self.n = n
    def update_item(self, Key, UpdateExpression, ExpressionAttributeValues):
        attr = UpdateExpression.split()[1]; TABLES[self.n][Key[KEYS[self.n]]][attr] = {"S": ExpressionAttributeValues[":n"]}
    def scan(self, **kw):
        d = TypeDeserializer(); return {"Items": [{k: d.deserialize(v) for k, v in i.items()} for i in TABLES[self.n].values()]}
def client(name): return {"dynamodb": _DDB(), "sns": _SNS(), "s3": _S3(), "stepfunctions": _SFN(), "sesv2": _SES(), "scheduler": _Scheduler(), "translate": _Translate()}[name]
class _Res:
    def Table(self, n): return _Table(n)
def resource(name): return _Res()
