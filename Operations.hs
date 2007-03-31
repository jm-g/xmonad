module Operations where

import Data.List
import Data.Maybe
import Data.Bits
import qualified Data.Map as M

import Control.Monad.State

import System.Posix.Process
import System.Environment

import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras

import XMonad

import qualified StackSet as W


-- ---------------------------------------------------------------------
-- Managing windows

-- | refresh. Refresh the currently focused window. Resizes to full
-- screen and raises the window.
refresh :: X ()
refresh = do
    ws     <- gets workspace
    ws2sc  <- gets wsOnScreen
    xinesc <- gets xineScreens
    d      <- gets display
    fls    <- gets layoutDescs
    dfltfl <- gets defaultLayoutDesc
    let move w a b c e = io $ moveResizeWindow d w a b c e
    flip mapM_ (M.assocs ws2sc) $ \(n, scn) -> do
        let sc = xinesc !! scn
            sx = rect_x sc
            sy = rect_y sc
            sw = rect_width sc
            sh = rect_height sc
            fl = M.findWithDefault dfltfl n fls
            l  = layoutType fl
            ratio = tileFraction fl
        case l of
            Full -> whenJust (W.peekStack n ws) $ \w -> do
                                                            move w sx sy sw sh
                                                            io $ raiseWindow d w
            Tile -> case W.index n ws of
                []    -> return ()
                [w]   -> do move w sx sy sw sh; io $ raiseWindow d w
                (w:s) -> do
                    let lw = floor $ fromIntegral sw * ratio
                        rw = sw - fromIntegral lw
                        rh = fromIntegral sh `div` fromIntegral (length s)
                    move w sx sy (fromIntegral lw) sh
                    zipWithM_ (\i a -> move a (sx + lw) (sy + i * rh) rw (fromIntegral rh)) [0..] s
                    whenJust (W.peek ws) (io . raiseWindow d) -- this is always Just
    whenJust (W.peek ws) setFocus

-- | switchLayout.  Switch to another layout scheme.  Switches the current workspace.
switchLayout :: X ()
switchLayout = layout $ \fl -> fl { layoutType = case layoutType fl of
                                                   Full -> Tile
                                                   Tile -> Full }

-- | changeWidth.  Change the width of the main window in tiling mode.
changeWidth :: Rational -> X ()
changeWidth delta = do
    layout $ \fl -> fl { tileFraction = min 1 $ max 0 $ tileFraction fl + delta }

-- | layout. Modify the current workspace's layout with a pure function and refresh.
layout :: (LayoutDesc -> LayoutDesc) -> X ()
layout f = do modify $ \s -> let fls = layoutDescs s
                                 n   = W.current . workspace $ s
                                 fl  = M.findWithDefault (defaultLayoutDesc s) n fls
                             in s { layoutDescs = M.insert n (f fl) fls }
              refresh
              

-- | windows. Modify the current window list with a pure function, and refresh
windows :: (WorkSpace -> WorkSpace) -> X ()
windows f = do
    modify $ \s -> s { workspace = f (workspace s) }
    refresh
    ws <- gets workspace
    trace (show ws) -- log state changes to stderr

-- | hide. Hide a window by moving it offscreen.
hide :: Window -> X ()
hide w = withDisplay $ \d -> do
    (sw,sh) <- gets dimensions
    io $ moveWindow d w (2*fromIntegral sw) (2*fromIntegral sh)

-- ---------------------------------------------------------------------
-- Window operations

-- | setButtonGrab. Tell whether or not to intercept clicks on a given window
buttonsToGrab :: [Button]
buttonsToGrab = [button1, button2, button3]

setButtonGrab :: Bool -> Window -> X ()
setButtonGrab True  w = withDisplay $ \d -> io $ flip mapM_ buttonsToGrab (\b ->
                            grabButton d b anyModifier w False
                                       (buttonPressMask .|. buttonReleaseMask)
                                       grabModeAsync grabModeSync none none)
setButtonGrab False w = withDisplay $ \d -> io $ flip mapM_ buttonsToGrab (\b ->
                            ungrabButton d b anyModifier w)

-- | manage. Add a new window to be managed in the current workspace. Bring it into focus.
-- If the window is already under management, it is just raised.
--
-- When we start to manage a window, it gains focus.
--
manage :: Window -> X ()
manage w = do
    withDisplay $ \d -> io $ do
        selectInput d w $ structureNotifyMask .|. enterWindowMask .|. propertyChangeMask
        mapWindow d w
    setFocus w
    windows $ W.push w

-- | unmanage. A window no longer exists, remove it from the window
-- list, on whatever workspace it is.
unmanage :: Window -> X ()
unmanage w = do
    windows $ W.delete w
    withServerX $ do
      setTopFocus
      withDisplay $ \d -> io (sync d False)
      -- TODO, everything operates on the current display, so wrap it up.

-- | Grab the X server (lock it) from the X monad
withServerX :: X () -> X ()
withServerX f = withDisplay $ \dpy -> do
    io $ grabServer dpy
    f
    io $ ungrabServer dpy

safeFocus :: Window -> X ()
safeFocus w = do ws <- gets workspace
                 if W.member w ws
                    then setFocus w
                    else do b <- isRoot w
                            when b setTopFocus

-- | Explicitly set the keyboard focus to the given window
setFocus :: Window -> X ()
setFocus w = do
    ws <- gets workspace
    ws2sc <- gets wsOnScreen
    -- clear mouse button grab and border on other windows
    flip mapM_ (M.keys ws2sc) $ \n -> do
        flip mapM_ (W.index n ws) $ \otherw -> do
            setButtonGrab True otherw
            setBorder otherw 0xdddddd

    withDisplay $ \d -> io $ setInputFocus d w revertToPointerRoot 0
    setButtonGrab False w
    setBorder w 0xff0000
    -- This does not use 'windows' intentionally.  'windows' calls refresh,
    -- which means infinite loops.
    modify (\s -> s { workspace = W.raiseFocus w (workspace s) })

-- | Set the focus to the window on top of the stack, or root
setTopFocus :: X ()
setTopFocus = do
    ws <- gets workspace
    case W.peek ws of
        Just new -> setFocus new
        Nothing  -> gets theRoot >>= setFocus

-- | Set the border color for a particular window.
setBorder :: Window -> Pixel -> X ()
setBorder w p = withDisplay $ \d -> io $ setWindowBorder d w p

-- | raise. focus to window at offset 'n' in list.
-- The currently focused window is always the head of the list
raise :: Ordering -> X ()
raise = windows . W.rotate

-- | promote.  Make the focused window the master window in its workspace
promote :: X ()
promote = windows (\w -> maybe w (\k -> W.promote k w) (W.peek w))

-- | Kill the currently focused client
kill :: X ()
kill = withDisplay $ \d -> do
    ws <- gets workspace
    whenJust (W.peek ws) $ \w -> do
        protocols <- io $ getWMProtocols d w
        wmdelt    <- gets wmdelete
        wmprot    <- gets wmprotocols
        if wmdelt `elem` protocols
            then io $ allocaXEvent $ \ev -> do
                    setEventType ev clientMessage
                    setClientMessageEvent ev w wmprot 32 wmdelt 0
                    sendEvent d w False noEventMask ev
            else io (killClient d w) >> return ()

-- | tag. Move a window to a new workspace
tag :: Int -> X ()
tag o = do
    ws <- gets workspace
    let m = W.current ws
    when (n /= m) $
        whenJust (W.peek ws) $ \w -> do
            hide w
            windows $ W.shift n
    where n = o-1

-- | view. Change the current workspace to workspce at offset 'n-1'.
view :: Int -> X ()
view o = do
    ws    <- gets workspace
    ws2sc <- gets wsOnScreen
    let m = W.current ws
    -- is the workspace we want to switch to currently visible?
    if M.member n ws2sc
        then windows $ W.view n
        else do 
            sc <- case M.lookup m ws2sc of
                Nothing -> do 
                    trace "Current workspace isn't visible! This should never happen!"
                    -- we don't know what screen to use, just use the first one.
                    return 0
                Just sc -> return sc
            modify $ \s -> s { wsOnScreen = M.insert n sc (M.filter (/=sc) ws2sc) }
            gets wsOnScreen >>= trace . show
            windows $ W.view n
            mapM_ hide (W.index m ws)
    setTopFocus
    where n = o-1

-- | True if window is under management by us
isClient :: Window -> X Bool
isClient w = liftM (W.member w) (gets workspace)

-- | screenWS. Returns the workspace currently visible on screen n
screenWS :: Int -> X Int
screenWS n = do
    ws2sc <- gets wsOnScreen
    -- FIXME: It's ugly to have to query this way. We need a different way to
    -- keep track of screen <-> workspace mappings.
    let ws = fmap fst $ find (\(_, scn) -> scn == (n-1)) (M.assocs ws2sc)
    return $ (fromMaybe 0 ws) + 1

-- | Restart xmonad by exec()'ing self. This doesn't save state and xmonad has
-- to be in PATH for this to work.
restart :: IO ()
restart = do prog <- getProgName
             args <- getArgs
             executeFile prog True args Nothing
