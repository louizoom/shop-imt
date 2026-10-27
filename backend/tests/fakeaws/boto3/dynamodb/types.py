from decimal import Decimal
class TypeDeserializer:
    def deserialize(self, v):
        (t, x), = v.items()
        if t == "S": return x
        if t == "N": return Decimal(x)
        if t == "L": return [self.deserialize(i) for i in x]
        raise NotImplementedError(t)
