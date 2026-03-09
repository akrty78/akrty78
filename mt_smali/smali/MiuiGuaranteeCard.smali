.class public Lcom/android/settings/device/MiuiGuaranteeCard;
.super Landroid/widget/FrameLayout;
.source "SourceFile"


# static fields
.field private static final VERSION_NUMBER:Ljava/lang/String; = "__NEXDROID_VERSION__"

.field private static final VERSION_SUFFIX:Ljava/lang/String; = "EX"


# instance fields
.field private mFragment:Lcom/android/settings/dashboard/DashboardFragment;

.field private mMiCareExpiryTime:Ljava/lang/String;


# direct methods
.method public constructor <init>(Landroid/content/Context;)V
    .registers 2

    .line 27
    invoke-direct {p0, p1}, Landroid/widget/FrameLayout;-><init>(Landroid/content/Context;)V

    .line 28
    invoke-direct {p0}, Lcom/android/settings/device/MiuiGuaranteeCard;->initView()V

    return-void
.end method

.method public constructor <init>(Landroid/content/Context;Landroid/util/AttributeSet;)V
    .registers 3

    .line 32
    invoke-direct {p0, p1, p2}, Landroid/widget/FrameLayout;-><init>(Landroid/content/Context;Landroid/util/AttributeSet;)V

    .line 33
    invoke-direct {p0}, Lcom/android/settings/device/MiuiGuaranteeCard;->initView()V

    return-void
.end method

.method private initView()V
    .registers 4

    .line 51
    iget-object v0, p0, Landroid/widget/FrameLayout;->mContext:Landroid/content/Context;

    invoke-static {v0}, Lcom/android/settings/device/MiuiGuaranteeCard;->isVisible(Landroid/content/Context;)Z

    move-result v0

    if-nez v0, :cond_e

    const/16 v0, 0x8

    .line 52
    invoke-virtual {p0, v0}, Landroid/widget/FrameLayout;->setVisibility(I)V

    return-void

    .line 55
    :cond_e
    iget-object v0, p0, Landroid/widget/FrameLayout;->mContext:Landroid/content/Context;

    const-string/jumbo v1, "micare_expiry_time"

    invoke-static {v0, v1}, Lcom/android/settings/device/MiCareUtils;->getMiCareInfoWithPrefKey(Landroid/content/Context;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    iput-object v0, p0, Lcom/android/settings/device/MiuiGuaranteeCard;->mMiCareExpiryTime:Ljava/lang/String;

    .line 56
    iget-object v0, p0, Landroid/widget/FrameLayout;->mContext:Landroid/content/Context;

    invoke-static {v0}, Landroid/view/LayoutInflater;->from(Landroid/content/Context;)Landroid/view/LayoutInflater;

    move-result-object v0

    sget v1, Lcom/android/settings/R$layout;->my_device_info_item:I

    const/4 v2, 0x1

    invoke-virtual {v0, v1, p0, v2}, Landroid/view/LayoutInflater;->inflate(ILandroid/view/ViewGroup;Z)Landroid/view/View;

    .line 57
    sget v0, Lcom/android/settings/R$id;->title:I

    invoke-virtual {p0, v0}, Landroid/widget/FrameLayout;->findViewById(I)Landroid/view/View;

    move-result-object v0

    check-cast v0, Landroid/widget/TextView;

    .line 58
    const-string v1, "Extended Build"

    invoke-virtual {v0, v1}, Landroid/widget/TextView;->setText(Ljava/lang/CharSequence;)V

    .line 59
    sget v0, Lcom/android/settings/R$id;->summary:I

    invoke-virtual {p0, v0}, Landroid/widget/FrameLayout;->findViewById(I)Landroid/view/View;

    move-result-object v0

    check-cast v0, Landroid/widget/TextView;

    .line 60
    new-instance v1, Ljava/lang/StringBuilder;

    invoke-direct {v1}, Ljava/lang/StringBuilder;-><init>()V

    .line 61
    sget-object v2, Lcom/android/settings/device/MiuiGuaranteeCard;->VERSION_NUMBER:Ljava/lang/String;

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    .line 62
    const-string v2, "."

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    .line 63
    sget-object v2, Lcom/android/settings/device/MiuiGuaranteeCard;->VERSION_SUFFIX:Ljava/lang/String;

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    .line 64
    iget-object p0, p0, Lcom/android/settings/device/MiuiGuaranteeCard;->mMiCareExpiryTime:Ljava/lang/String;

    invoke-virtual {v1, p0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    .line 65
    invoke-virtual {v1}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object p0

    invoke-virtual {v0, p0}, Landroid/widget/TextView;->setText(Ljava/lang/CharSequence;)V

    return-void
.end method

.method public static isVisible(Landroid/content/Context;)Z
    .registers 4

    const/4 v1, 0x1

    return v1
.end method


# virtual methods
.method public setFragment(Lcom/android/settings/dashboard/DashboardFragment;)V
    .registers 2

    .line 67
    iput-object p1, p0, Lcom/android/settings/device/MiuiGuaranteeCard;->mFragment:Lcom/android/settings/dashboard/DashboardFragment;

    return-void
.end method
