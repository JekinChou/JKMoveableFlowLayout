//
//  JKTagMoveFlowLayout.m
//  Aipai
//
//  Created by zhangjie on 2017/12/16.
//  Copyright © 2017年 www.aipai.com. All rights reserved.
//

#import "JKMoveableFlowLayout.h"
#import <objc/runtime.h>
CG_INLINE CGPoint
JKCGPointAdd(CGPoint point1, CGPoint point2) {
    return CGPointMake(point1.x + point2.x, point1.y + point2.y);
}
typedef NS_ENUM(NSInteger, JKScrollingDirection) {
    JKScrollingDirectionUnknown = 0,
    JKScrollingDirectionUp,
    JKScrollingDirectionDown,
    JKScrollingDirectionLeft,
    JKScrollingDirectionRight
};
static NSString * const kJKScrollingDirectionKey = @"JKScrollingDirection";
static NSString * const kJKCollectionViewKeyPath = @"collectionView";


@interface CADisplayLink (userInfo)
@property (nonatomic, copy) NSDictionary *userInfo;
@end

@implementation CADisplayLink (userInfo)
- (void) setUserInfo:(NSDictionary *) userInfo {
    objc_setAssociatedObject(self, "userInfo", userInfo, OBJC_ASSOCIATION_COPY);
}

- (NSDictionary *)userInfo {
    return objc_getAssociatedObject(self, "userInfo");
}
@end

@interface UICollectionViewCell (JKReorderableCollectionViewFlowLayout)
- (UIView *)snapshotView;
@end

@implementation UICollectionViewCell (JKReorderableCollectionViewFlowLayout)
- (UIView *)snapshotView {
    if ([self respondsToSelector:@selector(snapshotViewAfterScreenUpdates:)]) {
        return [self snapshotViewAfterScreenUpdates:YES];
    } else {
        UIGraphicsBeginImageContextWithOptions(self.bounds.size, self.isOpaque, 0.0f);
        [self.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [[UIImageView alloc] initWithImage:image];
    }
}

@end

// !!!:class 分割线 =========================================================================================================
@interface JKMoveableFlowLayout ()
@property (nonatomic,strong) NSIndexPath *selectedItemIndexPath;
@property (nonatomic,strong) UIView *currentView;
@property (nonatomic,assign) CGPoint currentViewCenter;
@property (nonatomic,assign) CGPoint panTranslationInCollectionView;
@property (nonatomic,strong) CADisplayLink *displayLink;
@property (assign, nonatomic, readonly) id<JKReorderableCollectionViewDataSource> dataSource;
@property (assign, nonatomic, readonly) id<JKReorderableCollectionViewDelegateFlowLayout> delegate;
@end
@implementation JKMoveableFlowLayout
@synthesize longPressGestureRecognizer = _longPressGestureRecognizer;
@synthesize panGestureRecognizer = _panGestureRecognizer;
- (void)dealloc {
    [self invalidatesScrollTimer];
    [self tearDownCollectionView];
    [self removeObserver:self forKeyPath:kJKCollectionViewKeyPath];
}
- (instancetype)init {
    if ( self = [super init]) {
        [self setDefaults];
        [self addObserver:self forKeyPath:kJKCollectionViewKeyPath options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder]) {
        [self setDefaults];
        [self addObserver:self forKeyPath:kJKCollectionViewKeyPath options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

#pragma mark - privateMethod
- (void)setDefaults {
    _scrollingSpeed = 300.0f;
    _scrollingTriggerEdgeInsets = UIEdgeInsetsMake(50.0f, 50.0f, 50.0f, 50.0f);
}
- (void)invalidatesScrollTimer {
    if (!self.displayLink.paused) {
        [self.displayLink invalidate];
    }
    self.displayLink = nil;
}
- (void)setupScrollTimerInDirection:(JKScrollingDirection)direction {
    if (!self.displayLink.paused) {
        JKScrollingDirection oldDirection = [self.displayLink.userInfo[kJKScrollingDirectionKey] integerValue];
        if (direction == oldDirection)  return;
    }
    [self invalidatesScrollTimer];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleScroll:)];
    self.displayLink.userInfo = @{ kJKScrollingDirectionKey : @(direction) };
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)tearDownCollectionView {
    if (_longPressGestureRecognizer) {
        UIView *view = _longPressGestureRecognizer.view;
        if (view) [view removeGestureRecognizer:_longPressGestureRecognizer];
        _longPressGestureRecognizer.delegate = nil;
        _longPressGestureRecognizer = nil;
    }
    
    if (_panGestureRecognizer) {
        UIView *view = _panGestureRecognizer.view;
        if (view) [view removeGestureRecognizer:_panGestureRecognizer];
        _panGestureRecognizer.delegate = nil;
        _panGestureRecognizer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
}

#pragma mark - Target/Action methods
- (void)handleLongPressGesture:(UILongPressGestureRecognizer *)gestureRecognizer {
    switch(gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan: {
            NSIndexPath *currentIndexPath = [self.collectionView indexPathForItemAtPoint:[gestureRecognizer locationInView:self.collectionView]];
            if (currentIndexPath == nil)  return;
            if ([self.dataSource respondsToSelector:@selector(collectionView:canMoveItemAtIndexPath:)] &&
                ![self.dataSource collectionView:self.collectionView canMoveItemAtIndexPath:currentIndexPath]) {
                return;
            }
            self.selectedItemIndexPath = currentIndexPath;
            if ([self.delegate respondsToSelector:@selector(collectionView:layout:willBeginDraggingItemAtIndexPath:)]) {
                [self.delegate collectionView:self.collectionView layout:self willBeginDraggingItemAtIndexPath:self.selectedItemIndexPath];
            }
            UICollectionViewCell *collectionViewCell = [self.collectionView cellForItemAtIndexPath:self.selectedItemIndexPath];
            self.currentView = [[UIView alloc] initWithFrame:collectionViewCell.frame];
            collectionViewCell.highlighted = YES;
            UIView *highlightedImageView = [collectionViewCell snapshotView];
            highlightedImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            highlightedImageView.alpha = 1.0f;
            collectionViewCell.highlighted = NO;
            UIView *imageView = [collectionViewCell snapshotView];
            imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            imageView.alpha = 0.0f;
            [self.currentView addSubview:imageView];
            [self.currentView addSubview:highlightedImageView];
            [self.collectionView addSubview:self.currentView];
            self.currentViewCenter = self.currentView.center;
            if ([self.delegate respondsToSelector:@selector(collectionView:layout:didBeginDraggingItemAtIndexPath:)]) {
                [self.delegate collectionView:self.collectionView layout:self didBeginDraggingItemAtIndexPath:self.selectedItemIndexPath];
            }
            
            @weakify(self);
            [UIView
             animateWithDuration:0.3
             delay:0.0
             options:UIViewAnimationOptionBeginFromCurrentState
             animations:^{
                 @strongify(self);
                 self.currentView.transform = CGAffineTransformMakeScale(1.1f, 1.1f);
                 highlightedImageView.alpha = 0.0f;
                 imageView.alpha = 1.0f;
             }
             completion:^(BOOL finished) {
                 [highlightedImageView removeFromSuperview];
             }];
            
            [self invalidateLayout];
        } break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateEnded: {
            NSIndexPath *currentIndexPath = self.selectedItemIndexPath;
            
            if (currentIndexPath) {
                if ([self.delegate respondsToSelector:@selector(collectionView:layout:willEndDraggingItemAtIndexPath:)]) {
                    [self.delegate collectionView:self.collectionView layout:self willEndDraggingItemAtIndexPath:currentIndexPath];
                }
                
                self.selectedItemIndexPath = nil;
                self.currentViewCenter = CGPointZero;
                
                UICollectionViewLayoutAttributes *layoutAttributes = [self layoutAttributesForItemAtIndexPath:currentIndexPath];
                
                self.longPressGestureRecognizer.enabled = NO;
                @weakify(self);
                [UIView
                 animateWithDuration:0.3
                 delay:0.0
                 options:UIViewAnimationOptionBeginFromCurrentState
                 animations:^{
                     @strongify(self);
                     self.currentView.transform = CGAffineTransformMakeScale(1.0f, 1.0f);
                     self.currentView.center = layoutAttributes.center;
                 }
                 completion:^(BOOL finished) {
                     self.longPressGestureRecognizer.enabled = YES;
                     @strongify(self);
                     [self.currentView removeFromSuperview];
                     self.currentView = nil;
                     [self invalidateLayout];
                     if ([self.delegate respondsToSelector:@selector(collectionView:layout:didEndDraggingItemAtIndexPath:)]) {
                         [self.delegate collectionView:self.collectionView layout:self didEndDraggingItemAtIndexPath:currentIndexPath];
                     }
                     
                 }];
            }
        } break;
            
        default: break;
    }
}
- (void)handlePanGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    switch (gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            self.panTranslationInCollectionView = [gestureRecognizer translationInView:self.collectionView];
            CGPoint viewCenter = self.currentView.center = JKCGPointAdd(self.currentViewCenter, self.panTranslationInCollectionView);
            
            [self invalidateLayoutIfNecessary];
            
            switch (self.scrollDirection) {
                case UICollectionViewScrollDirectionVertical: {
                    if (viewCenter.y < (CGRectGetMinY(self.collectionView.bounds) + self.scrollingTriggerEdgeInsets.top)) {
                        [self setupScrollTimerInDirection:JKScrollingDirectionUp];
                    } else {
                        if (viewCenter.y > (CGRectGetMaxY(self.collectionView.bounds) - self.scrollingTriggerEdgeInsets.bottom)) {
                            [self setupScrollTimerInDirection:JKScrollingDirectionDown];
                        } else {
                            [self invalidatesScrollTimer];
                        }
                    }
                } break;
                case UICollectionViewScrollDirectionHorizontal: {
                    if (viewCenter.x < (CGRectGetMinX(self.collectionView.bounds) + self.scrollingTriggerEdgeInsets.left)) {
                        [self setupScrollTimerInDirection:JKScrollingDirectionLeft];
                    } else {
                        if (viewCenter.x > (CGRectGetMaxX(self.collectionView.bounds) - self.scrollingTriggerEdgeInsets.right)) {
                            [self setupScrollTimerInDirection:JKScrollingDirectionRight];
                        } else {
                            [self invalidatesScrollTimer];
                        }
                    }
                } break;
            }
        } break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateEnded: {
            [self invalidatesScrollTimer];
        } break;
        default:
            
            break;
    }
}
- (void)handleScroll:(CADisplayLink *)displayLink {
    JKScrollingDirection direction = (JKScrollingDirection)[displayLink.userInfo[kJKScrollingDirectionKey] integerValue];
    if (direction == JKScrollingDirectionUnknown)  return;
    CGSize frameSize = self.collectionView.bounds.size;
    CGSize contentSize = self.collectionView.contentSize;
    CGPoint contentOffset = self.collectionView.contentOffset;
    UIEdgeInsets contentInset = self.collectionView.contentInset;
    CGFloat distance = rint(self.scrollingSpeed * displayLink.duration);
    CGPoint translation = CGPointZero;
    switch(direction) {
        case JKScrollingDirectionUp: {
            distance = -distance;
            CGFloat minY = 0.0f - contentInset.top;
            
            if ((contentOffset.y + distance) <= minY) {
                distance = -contentOffset.y - contentInset.top;
            }
            
            translation = CGPointMake(0.0f, distance);
        } break;
        case JKScrollingDirectionDown: {
            CGFloat maxY = MAX(contentSize.height, frameSize.height) - frameSize.height + contentInset.bottom;
            
            if ((contentOffset.y + distance) >= maxY) {
                distance = maxY - contentOffset.y;
            }
            
            translation = CGPointMake(0.0f, distance);
        } break;
        case JKScrollingDirectionLeft: {
            distance = -distance;
            CGFloat minX = 0.0f - contentInset.left;
            
            if ((contentOffset.x + distance) <= minX) {
                distance = -contentOffset.x - contentInset.left;
            }
            
            translation = CGPointMake(distance, 0.0f);
        } break;
        case JKScrollingDirectionRight: {
            CGFloat maxX = MAX(contentSize.width, frameSize.width) - frameSize.width + contentInset.right;
            
            if ((contentOffset.x + distance) >= maxX) {
                distance = maxX - contentOffset.x;
            }
            
            translation = CGPointMake(distance, 0.0f);
        } break;
        default:
            break;
    }
    self.currentViewCenter = JKCGPointAdd(self.currentViewCenter, translation);
    self.currentView.center = JKCGPointAdd(self.currentViewCenter, self.panTranslationInCollectionView);
    self.collectionView.contentOffset = JKCGPointAdd(contentOffset, translation);
}
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)layoutAttributes {
    if ([layoutAttributes.indexPath isEqual:self.selectedItemIndexPath]) {
        layoutAttributes.hidden = YES;
    }
}
- (void)invalidateLayoutIfNecessary {
    NSIndexPath *newIndexPath = [self.collectionView indexPathForItemAtPoint:self.currentView.center];
    NSIndexPath *previousIndexPath = self.selectedItemIndexPath;
    if ((newIndexPath == nil) || [newIndexPath isEqual:previousIndexPath])   return;
    if ([self.dataSource respondsToSelector:@selector(collectionView:itemAtIndexPath:canMoveToIndexPath:)] &&
        ![self.dataSource collectionView:self.collectionView itemAtIndexPath:previousIndexPath canMoveToIndexPath:newIndexPath]) {
        return;
    }
    self.selectedItemIndexPath = newIndexPath;
    if ([self.dataSource respondsToSelector:@selector(collectionView:itemAtIndexPath:willMoveToIndexPath:)]) {
        [self.dataSource collectionView:self.collectionView itemAtIndexPath:previousIndexPath willMoveToIndexPath:newIndexPath];
    }
    @weakify(self);
    [self.collectionView performBatchUpdates:^{
        @strongify(self);
        [self.collectionView deleteItemsAtIndexPaths:@[ previousIndexPath ]];
        [self.collectionView insertItemsAtIndexPaths:@[ newIndexPath ]];
    } completion:^(BOOL finished) {
        @strongify(self);
        if ([self.dataSource respondsToSelector:@selector(collectionView:itemAtIndexPath:didMoveToIndexPath:)]) {
            [self.dataSource collectionView:self.collectionView itemAtIndexPath:previousIndexPath didMoveToIndexPath:newIndexPath];
        }
    }];
}
#pragma mark - UICollectionViewLayout overridden methods
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSArray *layoutAttributesForElementsInRect = [super layoutAttributesForElementsInRect:rect];
    
    for (UICollectionViewLayoutAttributes *layoutAttributes in layoutAttributesForElementsInRect) {
        switch (layoutAttributes.representedElementCategory) {
            case UICollectionElementCategoryCell: {
                [self applyLayoutAttributes:layoutAttributes];
            } break;
            default: {
                // Do nothing...
            } break;
        }
    }
    
    return layoutAttributesForElementsInRect;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *layoutAttributes = [super layoutAttributesForItemAtIndexPath:indexPath];
    
    switch (layoutAttributes.representedElementCategory) {
        case UICollectionElementCategoryCell: {
            [self applyLayoutAttributes:layoutAttributes];
        } break;
        default: {
        } break;
    }
    
    return layoutAttributes;
}
#pragma mark - UIGestureRecognizerDelegate methods

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([self.panGestureRecognizer isEqual:gestureRecognizer]) {
        return (self.selectedItemIndexPath != nil);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([self.longPressGestureRecognizer isEqual:gestureRecognizer]) {
        return [self.panGestureRecognizer isEqual:otherGestureRecognizer];
    }
    if ([self.panGestureRecognizer isEqual:gestureRecognizer]) {
        return [self.longPressGestureRecognizer isEqual:otherGestureRecognizer];
    }
    return NO;
}

#pragma mark - NOtification
- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    self.panGestureRecognizer.enabled = NO;
    self.panGestureRecognizer.enabled = YES;
}
#pragma mark - KVO
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:kJKCollectionViewKeyPath]) {
        if (self.collectionView != nil) {
            self.longPressGestureRecognizer.delegate = self;
            self.panGestureRecognizer.delegate = self;
        } else {
            [self invalidatesScrollTimer];
            [self tearDownCollectionView];
        }
    }
}
#pragma mark - SET/GET
- (id<JKReorderableCollectionViewDataSource>)dataSource {
    return (id<JKReorderableCollectionViewDataSource>)self.collectionView.dataSource;
}

- (id<JKReorderableCollectionViewDelegateFlowLayout>)delegate {
    return (id<JKReorderableCollectionViewDelegateFlowLayout>)self.collectionView.delegate;
}
- (UILongPressGestureRecognizer *)longPressGestureRecognizer {
    if (!_longPressGestureRecognizer) {
        _longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                    action:@selector(handleLongPressGesture:)];
        for (UIGestureRecognizer *gestureRecognizer in self.collectionView.gestureRecognizers) {
            if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
                [gestureRecognizer requireGestureRecognizerToFail:_longPressGestureRecognizer];
            }
        }
        [self.collectionView addGestureRecognizer:_longPressGestureRecognizer];
        
    }
    return _longPressGestureRecognizer;
}
- (UIPanGestureRecognizer *)panGestureRecognizer {
    if(!_panGestureRecognizer){
        _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(handlePanGesture:)];
        
        [self.collectionView addGestureRecognizer:_panGestureRecognizer];
    }
    return _panGestureRecognizer;
}
@end
