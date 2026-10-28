#!/bin/bash

# ==============================================================================
# CONFIGURATION (À modifier avec vos propres chemins absolus)
# ==============================================================================

# Exemple : "/home/user/ISOs" | Permet au script d'afficher la liste des iso dans un dossier
ISO_DIR="/chemin/vers/dossier/iso"

# Exemple : "/var/lib/libvirt/images/KVM" | Permet d'enregistrer le fichier qcow2 ou on le souhaite              
BASE_VM_DIR="/chemin/vers/dossier/VM" 
# ==============================================================================

# Vérification des dépendances
for cmd in whiptail virt-install qemu-img virsh; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "\e[31mErreur : l'outil '$cmd' est introuvable. Veuillez l'installer.\e[0m"
        exit 1
    fi
done

# Fonction de gestion des annulations
check_cancel() {
    if [ $? -ne 0 ]; then
        clear
        echo -e "\e[33mInstallation annulée par l'utilisateur. Aucune VM n'a été créée.\e[0m"
        exit 1
    fi
}

BACKTITLE="Assistant de Création de Machine Virtuelle KVM/QEMU"

# Vérification des dossiers de base
if [ ! -d "$ISO_DIR" ]; then
    echo -e "\e[31mErreur : Le dossier ISO '$ISO_DIR' n'existe pas. Veuillez modifier la variable ISO_DIR dans le script.\e[0m"
    exit 1
fi
mkdir -p "$BASE_VM_DIR"

# 1. Nom de la VM
VM_NAME=$(whiptail --title "Identification" --backtitle "$BACKTITLE" --inputbox "Entrez le nom de la machine virtuelle :" 8 60 3>&1 1>&2 2>&3)
check_cancel

# 2. Sélection de l'ISO
mapfile -t ISO_FILES < <(find "$ISO_DIR" -maxdepth 1 -type f -iname "*.iso" -printf "%f\n" | sort)

if [ ${#ISO_FILES[@]} -eq 0 ]; then
    whiptail --title "Erreur Critique" --backtitle "$BACKTITLE" --msgbox "Aucun fichier .iso trouvé dans le dossier :\n$ISO_DIR" 8 60
    exit 1
fi

MENU_OPTIONS=()
for iso in "${ISO_FILES[@]}"; do
    MENU_OPTIONS+=("$iso" "")
done

SELECTED_ISO=$(whiptail --title "Image Système (ISO)" --backtitle "$BACKTITLE" --menu "Choisissez une image ISO dans $ISO_DIR :" 15 75 6 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)
check_cancel
VM_ISO="$ISO_DIR/$SELECTED_ISO"

# 3. Emplacement du dossier de stockage avec option de sous-dossier
if whiptail --title "Organisation du stockage" --backtitle "$BACKTITLE" --yesno "Voulez-vous créer un sous-dossier spécifique pour cette VM ?\n\nDossier cible : $BASE_VM_DIR/$VM_NAME" 10 75; then
    VM_DISK_DIR="$BASE_VM_DIR/$VM_NAME"
else
    VM_DISK_DIR="$BASE_VM_DIR"
fi

# 4. Taille du disque
VM_DISK_SIZE=$(whiptail --title "Stockage" --backtitle "$BACKTITLE" --inputbox "Taille du disque dur en Go :" 8 60 "70" 3>&1 1>&2 2>&3)
check_cancel

# 5. Mémoire vive (RAM)
VM_RAM=$(whiptail --title "Mémoire Vive" --backtitle "$BACKTITLE" --inputbox "Quantité de RAM allouée en Mo (ex: 4096 pour 4 Go) :" 8 60 "4096" 3>&1 1>&2 2>&3)
check_cancel

# 6. Processeurs virtuels
VM_VCPU=$(whiptail --title "Processeur" --backtitle "$BACKTITLE" --inputbox "Nombre de cœurs vCPU à allouer :" 8 60 "4" 3>&1 1>&2 2>&3)
check_cancel

# 7. Type d'OS
VM_OS=$(whiptail --title "Optimisation Système" --backtitle "$BACKTITLE" --inputbox "Variante d'OS (ex: win11, ubuntu22.04)\nLaissez 'generic' si vous n'êtes pas sûr :" 9 60 "win11" 3>&1 1>&2 2>&3)
check_cancel

# 8. Compatibilité Windows 11 (UEFI + TPM)
if whiptail --title "Compatibilité Windows 11" --backtitle "$BACKTITLE" --yesno "Voulez-vous activer le firmware UEFI et la puce vTPM 2.0 ?\n\n(Obligatoire pour Windows 11, nécessite le paquet 'swtpm')" 10 75; then
    WIN11_MODE="Oui"
    
    if ! command -v swtpm &> /dev/null; then
        whiptail --title "Dépendance manquante" --backtitle "$BACKTITLE" --msgbox "Erreur : 'swtpm' n'est pas installé.\n\nVeuillez annuler et lancer : sudo apt install swtpm swtpm-tools" 10 70
        exit 1
    fi
else
    WIN11_MODE="Non"
fi

# 9. Détermination du type de bus disque
if [[ "${VM_OS,,}" == *"win"* ]]; then
    DISK_BUS="sata"
    NET_MODEL="e1000e"
else
    DISK_BUS="virtio"
    NET_MODEL="virtio"
fi

# 10. Récapitulatif et Confirmation
SUMMARY="Veuillez confirmer les spécifications :

► Nom          : $VM_NAME
► CPU / RAM    : $VM_VCPU vCPU / $VM_RAM Mo
► Fichier ISO  : $SELECTED_ISO
► Emplacement  : $VM_DISK_DIR
► Disque Dur   : $VM_NAME.qcow2 ($VM_DISK_SIZE Go, bus $DISK_BUS)
► Profil OS    : $VM_OS
► UEFI + TPM   : $WIN11_MODE
► Démarrage    : Manuel"

whiptail --title "Validation Définitive" --backtitle "$BACKTITLE" --yesno "$SUMMARY" 16 75
check_cancel

# --- Lancement de la création ---
clear
echo -e "\e[1;34m[ℹ] Préparation de l'environnement...\e[0m"
mkdir -p "$VM_DISK_DIR"

echo -e "\e[1;34m[ℹ] Création du disque dur virtuel ${VM_NAME}.qcow2 (${VM_DISK_SIZE} Go)...\e[0m"
qemu-img create -f qcow2 "${VM_DISK_DIR}/${VM_NAME}.qcow2" "${VM_DISK_SIZE}G"

echo -e "\e[1;34m[ℹ] Génération de la configuration de '$VM_NAME'...\e[0m"

# Construction de la commande virt-install dans un tableau bash
VIRT_CMD=(
    virt-install
    --name "$VM_NAME"
    --vcpus "$VM_VCPU"
    --memory "$VM_RAM"
    --cdrom "$VM_ISO"
    --disk path="${VM_DISK_DIR}/${VM_NAME}.qcow2",format=qcow2,bus="$DISK_BUS"
    --network default,model=virtio
    --os-variant "$VM_OS"
    --graphics spice
    --print-xml 1
    --check path_in_use=off
)

# Ajout des options Windows 11 si demandé
if [ "$WIN11_MODE" = "Oui" ]; then
    VIRT_CMD+=(--boot uefi)
    VIRT_CMD+=(--tpm backend.type=emulator,backend.version=2.0,model=tpm-crb)
fi

# Exécution de la commande
"${VIRT_CMD[@]}" > "/tmp/${VM_NAME}.xml"

echo -e "\e[1;34m[ℹ] Enregistrement de la machine virtuelle dans KVM...\e[0m"
virsh define "/tmp/${VM_NAME}.xml"
STATUS=$?

rm -f "/tmp/${VM_NAME}.xml"

if [ $STATUS -eq 0 ]; then
    echo -e "\n\e[1;32m[✔] Succès : La machine virtuelle '$VM_NAME' est prête dans $VM_DISK_DIR !\e[0m"
    echo -e "Pour la démarrer manuellement, ouvrez virt-manager ou tapez :"
    echo -e "  \e[1;33mvirsh start $VM_NAME\e[0m"
else
    echo -e "\n\e[1;31m[✖] Échec : Une erreur est survenue lors de l'enregistrement de la VM.\e[0m"
fi