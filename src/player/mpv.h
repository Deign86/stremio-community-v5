#ifndef MPVRENDERER_H_
#define MPVRENDERER_H_
#define MPV_ENABLE_DEPRECATED 0

#include <QtQuick/QQuickFramebufferObject>

#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <mpv/qthelper.hpp>

class MpvRenderer;

class MpvObject : public QQuickFramebufferObject
{
    Q_OBJECT
    // true while a file is loaded and not paused, regardless of what the web UI asked for
    Q_PROPERTY(bool playing READ isPlaying NOTIFY playingChanged)

    mpv_handle *mpv;
    mpv_render_context *mpv_gl;

    friend class MpvRenderer;

public:

    static void on_update(void *ctx);

    MpvObject(QQuickItem * parent = 0);
    virtual ~MpvObject();
    virtual Renderer *createRenderer() const;
    bool isPlaying() const { return !idle && !paused; }

    public slots:
        void command(const QVariant& params);
    void setProperty(const QString& name, const QVariant& value);
    QVariant getProperty(const QString& name);
    void observeProperty(const QString& name);

    signals:
        void onUpdate();
    void mpvEvent(const QString& ev, const QVariant& value);
    void playingChanged();

    private slots:
        void doUpdate();
    void on_mpv_events();

private:
    static void wakeup(void *ctx);
    void handle_mpv_event(mpv_event *event);
    void initialize_mpv();
    void handle_playback_state(mpv_event_property *prop);
    QSet<QString> observed_properties;
    bool idle = true;
    bool paused = false;
};

#endif
