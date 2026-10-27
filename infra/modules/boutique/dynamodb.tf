# Mode PROVISIONED : couvert par le Free Tier permanent de DynamoDB (25 RCU / 25 WCU et 25 Go
# au total pour le compte) : prod 4 x 5 = 20, dev 4 x 1 = 4, soit 24 au total. Le mode on-demand serait facturé à la requête.
# Chiffrement au repos : clé détenue par AWS (gratuit, activé par défaut).

resource "aws_dynamodb_table" "produits" {
  name           = "${var.prefix}-produits"
  billing_mode   = "PROVISIONED"
  read_capacity  = var.capacite_dynamodb
  write_capacity = var.capacite_dynamodb
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "commandes" {
  name           = "${var.prefix}-commandes"
  billing_mode   = "PROVISIONED"
  read_capacity  = var.capacite_dynamodb
  write_capacity = var.capacite_dynamodb
  hash_key       = "order_id"

  # Flux (streaming) des modifications : déclenche la publication des nouvelles commandes.
  # Lecture par un déclencheur Lambda gratuite.
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  attribute {
    name = "order_id"
    type = "S"
  }

  attribute {
    name = "client_sub"
    type = "S"
  }

  attribute {
    name = "cree_le"
    type = "S"
  }

  attribute {
    name = "jour"
    type = "S"
  }

  # Index « Mes commandes » : commandes d'un client connecté, triées par date.
  # Index creux : seules les commandes passées avec un compte y figurent.
  # 5/5 de plus : 15 RCU et 15 WCU au total, sous les 25 gratuits.
  global_secondary_index {
    name            = "par-client"
    hash_key        = "client_sub"
    range_key       = "cree_le"
    projection_type = "ALL"
    read_capacity   = var.capacite_dynamodb
    write_capacity  = var.capacite_dynamodb
  }

  # Index « par-jour » : commandes d'une journée (AAAA-MM-JJ), triées par heure. Sert l'interface admin
  # (liste et statistiques) sans jamais parcourir toute la table. 20 RCU / 20 WCU au total, sous les 25 gratuits.
  global_secondary_index {
    name            = "par-jour"
    hash_key        = "jour"
    range_key       = "cree_le"
    projection_type = "ALL"
    read_capacity   = var.capacite_dynamodb
    write_capacity  = var.capacite_dynamodb
  }
}

locals {
  catalogue = {
    p001 = { nom = "T-shirt IMT", prix = "19.90", stock = 50 }
    p002 = { nom = "Sweat à capuche", prix = "39.90", stock = 30 }
    p003 = { nom = "Mug cloud", prix = "9.50", stock = 100 }
    p004 = { nom = "Casquette", prix = "14.00", stock = 40 }
    p005 = { nom = "Carnet de notes", prix = "6.90", stock = 80 }
    p006 = { nom = "Gourde inox (série limitée)", prix = "17.50", stock = 5 }
  }
}

# Jeu de données initial. ignore_changes : le stock évolue avec les commandes,
# Terraform ne doit pas le remettre à zéro à chaque apply.
resource "aws_dynamodb_table_item" "produit" {
  for_each   = local.catalogue
  table_name = aws_dynamodb_table.produits.name
  hash_key   = aws_dynamodb_table.produits.hash_key

  item = jsonencode({
    id    = { S = each.key }
    nom   = { S = each.value.nom }
    prix  = { N = each.value.prix }
    stock = { N = tostring(each.value.stock) }
  })

  lifecycle {
    ignore_changes = [item]
  }
}
